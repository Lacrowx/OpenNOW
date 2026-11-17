import AVFoundation
import AVKit
import GameController
import SwiftUI
import UIKit

/// Wraps decoded pixel buffers for an `AVSampleBufferDisplayLayer`. Called on the decoder's queue.
final class TVFrameRenderer: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    /// Called on the decoder's queue when the decoded video format changes.
    var onFormatChange: (@Sendable (CMVideoFormatDescription) -> Void)?

    init(layer: AVSampleBufferDisplayLayer) { renderer = layer.sampleBufferRenderer }

    func enqueue(_ frame: NativeStreamNVSTFrame) {
        lock.lock(); defer { lock.unlock() }
        if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: frame.pixelBuffer) }) ?? true {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer, formatDescriptionOut: &format)
            if let format { onFormatChange?(format) }
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixelBuffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        // A game stream has no playback timeline: show each frame as soon as it is decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

/// One measurement of the running stream as the stream menu shows it.
struct TVStreamFigure: Hashable {
    let label: String
    let value: String
}

enum TVStreamMenuItem: String {
    case resume = "Resume"
    case showStats = "Show Stats"
    case hideStats = "Hide Stats"
    case leftTriggerFeel = "L2 Feel"
    case rightTriggerFeel = "R2 Feel"
    case leave = "Leave Stream"
    case endSession = "End Session"
    case keepPlaying = "Keep Playing"
    case confirmEndSession = "End Session Now"
    case retry = "Try Again"
    case close = "Close"
}

/// Owns one native NVST stream on tvOS: session start/stop, controller input, and the in-stream menu.
@MainActor
final class TVStreamCoordinator: NSObject, ObservableObject {
    @Published private(set) var status = "Connecting"
    @Published private(set) var detail = ""
    @Published private(set) var failed = false
    @Published private(set) var videoActive = false
    /// What the stream menu shows of the running stream, in display order.
    @Published private(set) var figures: [TVStreamFigure] = []
    /// The figures of the stats HUD, in display order; empty until the first measurement.
    @Published private(set) var hudItems: [String] = []
    @Published private(set) var statsVisible: Bool
    @Published private(set) var menuVisible = false
    @Published private(set) var selection = 0
    /// The menu is asking whether to end the session, which closes the game on the host.
    @Published private(set) var confirmingEnd = false
    /// Set while HDR video is playing; the stream screen asks tvOS to match the TV to it.
    @Published private(set) var displayCriteria: AVDisplayCriteria?

    /// The menu is drawn and navigated by this class, not the tvOS focus engine: controller
    /// input stays away from UIKit for the whole stream, so Back can never leave the app.
    var menuItems: [TVStreamMenuItem] {
        if confirmingEnd { return [.keepPlaying, .confirmEndSession] }
        if failed { return (canRetry ? [.retry] : []) + [.close, .endSession] }
        guard menuVisible else { return [] }
        // Only a DualSense has triggers to shape.
        let dualSense = GCController.controllers().contains { $0.extendedGamepad is GCDualSenseGamepad }
        return [.resume, statsVisible ? .hideStats : .showStats] + (dualSense ? [.leftTriggerFeel, .rightTriggerFeel] : [])
            + [.leave, .endSession]
    }

    /// Ends the session on the host. Set by the stream screen.
    var onEndSession: (() -> Void)?

    /// The fixed feel of each trigger for this game, chosen in the menu and remembered per game.
    @Published private(set) var triggerFeels: TVTriggerFeels

    func title(of item: TVStreamMenuItem) -> String {
        switch item {
        case .leftTriggerFeel: "\(item.rawValue): \(triggerFeels.left.title)"
        case .rightTriggerFeel: "\(item.rawValue): \(triggerFeels.right.title)"
        // Behind a failure there is nothing to keep playing.
        case .keepPlaying: failed ? "Keep Session" : item.rawValue
        default: item.rawValue
        }
    }

    var statsPosition: StreamStatsPosition { settings.streamerPreferences.statsPosition }
    var showsClock: Bool { settings.streamerPreferences.showStatsClock }

    let session: ActiveSession
    let canRetry: Bool
    let displayLayer = AVSampleBufferDisplayLayer()

    private let settings: AppSettings
    private let membershipTier: String?
    private let sessionHistory: StreamSessionHistoryStore?
    private let onStatsOverlayChange: (Bool) -> Void
    private let onRuntimeSample: (StreamRuntimeSample) -> Void
    private let onTransportStable: () -> Void
    private let onStreamTermination: (NvstSeatTermination) -> Void
    private let onTransportFailure: () -> Void
    private let onClose: () -> Void
    private let onRetry: (() -> Void)?
    private let inputBridge = NativeStreamInputBridge()
    private let triggerFeelStore = TVTriggerFeelStore()
    private lazy var renderer = TVFrameRenderer(layer: displayLayer)
    private var transport: NativeStreamNVST?
    private var startTask: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var statsReader = TVStreamStats()
    private var historyRecord: StreamSessionRecord?
    /// The codec in use, as the HUD and the session report name it.
    private var codecLabel = ""
    private var menuPoll: Timer?
    /// Consecutive polls a game controller's Options/Menu button has been held.
    private var menuHoldPolls = 0
    private static let menuHoldThreshold = 20 // polls at 50 ms: one second
    private var started = false
    private var stopped = false
    private var reportedStable = false
    /// Latency diagnostics since the last `[TVStream] stats` line, in seconds: how old a controller
    /// event was when its handler ran, and how long the handler-to-socket hand-off took.
    private var inputTimings = (count: 0, eventAge: 0.0, eventAgeMax: 0.0, send: 0.0, sendMax: 0.0)
    /// Every input packet in the same window, and the smallest unfiltered event age, so an empty
    /// `inputTimings` can be told apart from "no controller input".
    private var inputSends = 0
    private var inputRawAgeMin = Double.infinity
    private var samplesSinceStatsLog = 0

    init(session: ActiveSession, settings: AppSettings, membershipTier: String?,
         sessionHistory: StreamSessionHistoryStore?,
         onStatsOverlayChange: @escaping (Bool) -> Void,
         onRuntimeSample: @escaping (StreamRuntimeSample) -> Void,
         onTransportStable: @escaping () -> Void,
         onStreamTermination: @escaping (NvstSeatTermination) -> Void,
         onTransportFailure: @escaping () -> Void,
         onClose: @escaping () -> Void,
         onRetry: (() -> Void)?) {
        self.session = session
        self.settings = settings
        triggerFeels = TVTriggerFeelStore().feels(forGame: session.game.id)
        self.membershipTier = membershipTier
        self.sessionHistory = sessionHistory
        self.onStatsOverlayChange = onStatsOverlayChange
        self.onRuntimeSample = onRuntimeSample
        statsVisible = settings.showStatsOverlay
        self.onTransportStable = onTransportStable
        self.onStreamTermination = onStreamTermination
        self.onTransportFailure = onTransportFailure
        self.onClose = onClose
        self.onRetry = onRetry
        canRetry = onRetry != nil
        super.init()
        displayLayer.videoGravity = settings.streamerPreferences.stretchStreamToFill ? .resize : .resizeAspect
        inputBridge.sink = self
        inputBridge.configureUserPreferences(
            mouseSensitivity: settings.mouseSensitivity,
            mouseAcceleration: settings.mouseAcceleration,
            phoneRumbleFallback: false,
            physicalControllerPassthrough: true,
            controllerMouseEmulation: settings.controllerMouseEmulation,
            mouseScrollSensitivity: settings.mouseScrollSensitivity,
            controllerRumbleStrength: settings.controllerRumbleStrength)
        inputBridge.setTriggerRumbleStrength(settings.triggerRumbleStrength)
        inputBridge.setFixedTriggerEffects(left: triggerFeels.left.effect, right: triggerFeels.right.effect)
        inputBridge.onControllerHUDCommand = { [weak self] command in
            Task { @MainActor in self?.handleMenu(command) }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        inputBridge.attach()
        UIApplication.shared.isIdleTimerDisabled = true
        startMenuPolling()
        // A suspended app loses the stream's sockets, so the stream is closed on the way out. The
        // session keeps running on the host and can be rejoined from the app.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leave() }
        }
        guard !(session.nativeRtspsEndpoints ?? []).isEmpty else {
            fail("This session has no native streaming endpoint. End it and start the game again.")
            return
        }
        let report = NativeStreamCodecProbe.report()
        let codec = NativeStreamVideoCodec.normalized(settings.preferredCodec)
            ?? [.h265, .av1, .h264].first { report.capability(for: $0)?.videoToolboxHardwareDecode == true } ?? .h264
        guard report.capability(for: codec)?.videoToolboxHardwareDecode == true else {
            fail("\(codec.rawValue) hardware decoding is unavailable on this Apple TV.")
            return
        }
        var profile = StreamSettingsResolver.profile(for: settings, membershipTier: membershipTier)
        if let negotiated = session.negotiatedStreamProfile, let resolution = negotiated.resolution {
            let parts = resolution.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                profile = StreamVideoProfile(width: parts[0], height: parts[1],
                    fps: negotiated.fps ?? profile.fps, maxBitrateKbps: profile.maxBitrateKbps)
            }
        }
        detail = "\(codec.rawValue) \(profile.resolutionString) @ \(profile.fps) fps"
        tvStreamDebug("[TVStream] start \(detail) endpoints=\(session.nativeRtspsEndpoints?.count ?? 0) display=\(UIScreen.main.maximumFramesPerSecond)Hz")
        codecLabel = codec.rawValue
        historyRecord = StreamSessionRecord(gameTitle: session.game.title,
            resolution: "\(profile.width)×\(profile.height)", targetFPS: profile.fps, codec: codecLabel,
            hdr: settings.hdrEnabled, transport: "Native NVST")
        checkpointHistory(ended: false)

        let renderer = renderer
        let fps = Float(profile.fps)
        renderer.onFormatChange = { [weak self] format in
            Task { @MainActor in self?.videoFormatChanged(format, fps: fps) }
        }
        let transport = NativeStreamNVST(allocation: session, settings: settings, profile: profile, codec: codec,
            displayFPS: max(profile.fps, UIScreen.main.maximumFramesPerSecond),
            onFrame: { renderer.enqueue($0) },
            onSample: { [weak self] sample in Task { @MainActor in self?.update(sample) } },
            onFailure: { [weak self] reason in Task { @MainActor in self?.transportFailed(reason) } },
            onTermination: { [weak self] event in Task { @MainActor in self?.terminated(event) } },
            onHaptics: { [weak self] events in Task { @MainActor in
                guard let self, !self.stopped else { return }
                for event in events {
                    self.inputBridge.applyRumble(controllerId: Int(event.gamepadIndex),
                        weakMagnitude: Int(event.rightMotor), strongMagnitude: Int(event.leftMotor))
                }
            } },
            onProgress: { [weak self] stage in Task { @MainActor in
                guard let self, !self.stopped, !self.videoActive, !self.failed else { return }
                self.status = "Connecting"
                self.detail = TVStreamProgress.line(for: stage)
                tvStreamDebug("[TVStream] stage \(stage.rawValue)")
            } },
            onDiagnostic: { tvStreamDebug("[TVStream] nvst: \($0)") })
        self.transport = transport
        startTask = Task { [weak self] in
            do {
                await transport.setDualSenseHandlers(
                    onRoute: { [weak self] gamepadIndex, accepted in Task { @MainActor in
                        guard let self, !self.stopped else { return }
                        self.inputBridge.dualSenseRouteAnswered(controllerId: gamepadIndex, accepted: accepted)
                    } },
                    onOutput: { [weak self] gamepadIndex, output in Task { @MainActor in
                        guard let self, !self.stopped else { return }
                        self.inputBridge.applyDualSenseOutput(controllerId: gamepadIndex, output: output)
                    } })
                try await transport.start()
                guard let self, !self.stopped, !self.failed else { return }
                let hid = await transport.seatHidCapability
                tvStreamDebug("[TVStream] hid seat \(hid?.summary ?? "states no hidDeviceMask")")
                // First, so a DualSense that is offered as itself is not announced as a DualShock 4 in between.
                self.inputBridge.setDualSensePassthrough(self.settings.dualSensePassthrough)
                self.inputBridge.setDualShock4HIDAvailable(hid?.supportsDualShock4 == true)
                self.status = "Waiting for video"
            } catch {
                guard let self, !self.stopped, !Task.isCancelled,
                      !OpenNOWErrorPresenter.isCancellation(error) else { return }
                self.transportFailed(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        displayCriteria = nil
        TVDisplayMode.streamEnded()
        startTask?.cancel(); startTask = nil
        menuPoll?.invalidate(); menuPoll = nil
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        checkpointHistory(ended: true)
        inputBridge.detach()
        UIApplication.shared.isIdleTimerDisabled = false
        let transport = transport; self.transport = nil
        let renderer = renderer
        Task { await transport?.close(); renderer.flush() }
    }

    func leave() { stop(); onClose() }

    /// An Apple TV with Match Content on idles in SDR and enters HDR only for a video that asks.
    private func videoFormatChanged(_ format: CMVideoFormatDescription, fps: Float) {
        guard !stopped else { return }
        let transfer = CMFormatDescriptionGetExtension(format,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        let hdr = transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
            || transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        // Decided on the video that arrives, not the HDR setting: a stream requested as HDR is often
        // SDR. When the display is held in a mode for this video (fixed in Settings, or a high-refresh
        // one) it is selected directly; the system's own mode matching stays at 60 Hz, so it is only
        // the fallback for HDR.
        let modeHeld = TVDisplayMode.streamVideo(fps: Int(fps),
            width: Int(CMVideoFormatDescriptionGetDimensions(format).width), hdr: hdr)
        displayCriteria = hdr && !modeHeld ? AVDisplayCriteria(refreshRate: fps, formatDescription: format) : nil
        tvStreamDebug("[TVStream] video format transfer=\(transfer ?? "none") hdr=\(hdr)")
    }

    func retry() { stop(); onRetry?() }

    private func update(_ sample: NativeStreamNVSTSample) {
        guard !stopped, !failed else { return }
        if sample.decoded > 0 {
            if !videoActive { tvStreamDebug("[TVStream] video active: \(sample.detail)") }
            videoActive = true
            if !reportedStable { reportedStable = true; onTransportStable() }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let reading = statsReader.read(sample, at: now)
        let ping = reading.pingMs.map { "\($0) ms" } ?? "–"
        let thermal = ProcessInfo.processInfo.thermalState
        hudItems = reading.hudItems(metrics: settings.streamStatsMetrics, codec: codecLabel,
            gpu: Self.reported(session.gpuType), server: Self.reported(session.zone))
            + [thermal.tvHUDText].compactMap { $0 }
        figures = [
            TVStreamFigure(label: "Video", value: sample.resolution ?? "pending"),
            TVStreamFigure(label: "Frame rate", value: reading.decodedFPS.map { "\($0) fps" } ?? "–"),
            TVStreamFigure(label: "Bitrate", value: reading.bitrateText ?? "–"),
            TVStreamFigure(label: "Ping", value: ping),
            TVStreamFigure(label: "Decode", value: reading.decodeMs.map { String(format: "%.1f ms", $0) } ?? "–"),
            TVStreamFigure(label: "Packets lost", value: "\(sample.lost)"),
            TVStreamFigure(label: "Format", value: sample.bitstream),
            TVStreamFigure(label: "Thermal", value: thermal.tvLabel),
        ]
        onRuntimeSample(StreamRuntimeSample(timestamp: now, pingMs: reading.pingMs, bitrateKbps: reading.bitrateKbps,
            jitterMs: reading.jitterMs, fps: reading.decodedFPS, receivedFps: reading.receivedFPS,
            decodedFps: reading.decodedFPS, decodeMs: reading.decodeMs, packetsLostDelta: reading.packetsLostDelta,
            packetsReceivedDelta: reading.packetsReceivedDelta, packetLossPercent: reading.lossPercent,
            resolution: reading.resolution, codec: codecLabel))
        checkpointHistory(ended: false)
        samplesSinceStatsLog += 1
        if samplesSinceStatsLog >= 5 { logStats(sample, ping: ping) }
    }

    private func logStats(_ sample: NativeStreamNVSTSample, ping: String) {
        let input = inputTimings
        let count = Double(max(1, input.count))
        tvStreamDebug(String(format: "[TVStream] stats ping=%@ jitter=%.1fms lost=%d input[sends=%d rawAgeMin=%.2f n=%d age mean=%.2f max=%.2f send mean=%.2f max=%.2f]ms ",
                     ping, sample.jitterMilliseconds, sample.lost, inputSends, inputRawAgeMin * 1000, input.count,
                     input.eventAge / count * 1000, input.eventAgeMax * 1000,
                     input.send / count * 1000, input.sendMax * 1000) + sample.detail)
        inputTimings = (0, 0, 0, 0, 0)
        inputSends = 0
        inputRawAgeMin = .infinity
        samplesSinceStatsLog = 0
    }

    /// Nil for a value the provider left out or sent blank.
    private static func reported(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Saves how long the session has run so far. The history store writes to disk at most every
    /// half minute unless the session has ended.
    private func checkpointHistory(ended: Bool) {
        guard var record = historyRecord, record.endedAt == nil else { return }
        record.updatedAt = Date()
        if ended { record.endedAt = record.updatedAt }
        historyRecord = record
        sessionHistory?.update(record, force: ended)
    }

    private func setStatsVisible(_ visible: Bool) {
        statsVisible = visible
        onStatsOverlayChange(visible)
    }

    private func recordInput(eventAge: TimeInterval?, send: TimeInterval) {
        inputSends += 1
        if let eventAge { inputRawAgeMin = min(inputRawAgeMin, eventAge) }
        // Timer-driven keepalives carry no fresh controller event; only time real ones.
        guard let eventAge, eventAge >= 0, eventAge < 0.05 else { return }
        inputTimings.count += 1
        inputTimings.eventAge += eventAge
        inputTimings.eventAgeMax = max(inputTimings.eventAgeMax, eventAge)
        inputTimings.send += send
        inputTimings.sendMax = max(inputTimings.sendMax, send)
    }

    private func transportFailed(_ reason: String) {
        guard !stopped, !failed else { return }
        fail(reason)
        onTransportFailure()
    }

    private func fail(_ reason: String) {
        failed = true
        menuVisible = false
        confirmingEnd = false
        selection = 0
        inputBridge.setControllerHUDActive(true)
        videoActive = false
        status = "Stream failed"
        detail = TVStreamFailureMessage.plain(reason)
        TVStreamLog.failure(reason); tvStreamDebug("[TVStream] failed: \(reason)")
    }

    private func terminated(_ event: NvstSeatTermination) {
        guard !stopped else { return }
        stop()
        onStreamTermination(event)
    }

    private func setMenuVisible(_ visible: Bool) {
        guard menuVisible != visible, !failed else { return }
        selection = 0
        confirmingEnd = false
        menuVisible = visible
        // Releases the game's buttons while the menu owns the controller, and blocks held ones on return.
        inputBridge.setControllerHUDActive(visible)
    }

    /// Opens the question with "Keep Playing" selected; leaving it returns to "End Session".
    private func setConfirmingEnd(_ confirming: Bool) {
        confirmingEnd = confirming
        selection = confirming ? 0 : menuItems.count - 1
    }

    /// Menu navigation from a game controller (via the input bridge) or the Siri Remote.
    func handleMenu(_ command: NativeStreamControllerHUDCommand) {
        let items = menuItems
        guard !stopped, !items.isEmpty else { return }
        switch command {
        case .up: selection = max(0, selection - 1)
        case .down: selection = min(items.count - 1, selection + 1)
        // Nothing is left to resume behind a failure, so Back closes it.
        case .back: if confirmingEnd { setConfirmingEnd(false) } else if failed { leave() } else { setMenuVisible(false) }
        case .activate:
            switch items[min(selection, items.count - 1)] {
            case .resume: setMenuVisible(false)
            case .endSession: setConfirmingEnd(true)
            case .keepPlaying: setConfirmingEnd(false)
            case .confirmEndSession: stop(); onEndSession?()
            case .showStats: setStatsVisible(true)
            case .hideStats: setStatsVisible(false)
            case .leftTriggerFeel, .rightTriggerFeel: stepTriggerFeel(items[min(selection, items.count - 1)], by: 1)
            case .leave, .close: leave()
            case .retry: retry()
            }
        case .left: stepTriggerFeel(items[min(selection, items.count - 1)], by: -1)
        case .right: stepTriggerFeel(items[min(selection, items.count - 1)], by: 1)
        }
    }

    /// Moves a trigger's feel on in its list. The trigger takes it at once, so it can be tried
    /// with the menu still open, and the choice is kept for this game.
    private func stepTriggerFeel(_ item: TVStreamMenuItem, by steps: Int) {
        switch item {
        case .leftTriggerFeel: triggerFeels.left = triggerFeels.left.stepped(by: steps)
        case .rightTriggerFeel: triggerFeels.right = triggerFeels.right.stepped(by: steps)
        default: return
        }
        triggerFeelStore.set(triggerFeels, forGame: session.game.id)
        inputBridge.setFixedTriggerEffects(left: triggerFeels.left.effect, right: triggerFeels.right.effect)
        tvStreamDebug("[TVStream] trigger feels L2=\(triggerFeels.left.rawValue) R2=\(triggerFeels.right.rawValue) game=\(session.game.id)")
    }

    /// Controller input bypasses UIKit for the whole stream, so the menu is opened by reading the
    /// devices directly. tvOS reserves the DualSense Create button and the PS button, so a game
    /// controller opens the menu by holding Options/Menu for a second, as GeForce NOW does on TVs.
    private func startMenuPolling() {
        menuPoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMenuHold() }
        }
    }

    private func pollMenuHold() {
        let held = GCController.controllers().contains { $0.extendedGamepad?.buttonMenu.isPressed ?? false }
        menuHoldPolls = held ? menuHoldPolls + 1 : 0
        guard !stopped, menuHoldPolls == Self.menuHoldThreshold, menuItems.isEmpty else { return }
        setMenuVisible(true)
    }

    /// Siri Remote buttons, passed on by the stream screen as UIKit presses. GameController reports
    /// every clickpad click as Button A, ring clicks included, so it cannot tell Down from Select.
    func remotePressed(_ type: UIPress.PressType) {
        guard !stopped else { return }
        switch type {
        case .menu: if menuItems.isEmpty { setMenuVisible(true) } else { handleMenu(.back) }
        case .upArrow: handleMenu(.up)
        case .downArrow: handleMenu(.down)
        case .select: handleMenu(.activate)
        default: break
        }
    }
}

#if DEBUG
extension TVStreamCoordinator {
    /// `--opennow-stream-menu-preview`: the menu (or the failed panel) open over a stream that is
    /// never started, with sample figures.
    func installMenuPreview(failed: Bool) {
        if failed {
            fail("The connection to the server was lost.")
            return
        }
        videoActive = true
        hudItems = ["119 fps", "24 ms", "48.6 Mbps", "loss 0.1%", "3840x2160"]
        figures = [
            TVStreamFigure(label: "Video", value: "3840x2160"),
            TVStreamFigure(label: "Frame rate", value: "119 fps"),
            TVStreamFigure(label: "Bitrate", value: "48.6 Mbps"),
            TVStreamFigure(label: "Ping", value: "24 ms"),
            TVStreamFigure(label: "Decode", value: "5.8 ms"),
            TVStreamFigure(label: "Packets lost", value: "12"),
            TVStreamFigure(label: "Format", value: "10-bit 4:2:0"),
            TVStreamFigure(label: "Thermal", value: ProcessInfo.processInfo.thermalState.tvLabel),
        ]
        setMenuVisible(true)
    }
}
#endif

extension TVStreamCoordinator: NativeStreamInputSink {
    nonisolated func sendReliableInput(_ data: Data) { forward(data) }

    nonisolated func sendPartiallyReliableInput(_ data: Data) { forward(data) }

    /// Both input channels share the native transport's single send path.
    nonisolated private func forward(_ data: Data) {
        let calledAt = ProcessInfo.processInfo.systemUptime
        // Controller event timestamps are wall-clock seconds (measured against both uptime clocks).
        let eventClock = Date().timeIntervalSince1970
        let eventAt = GCController.controllers().compactMap { $0.extendedGamepad?.lastEventTimestamp }.max()
        Task { @MainActor in
            _ = await self.transport?.send(data)
            self.recordInput(eventAge: eventAt.map { eventClock - $0 },
                             send: ProcessInfo.processInfo.systemUptime - calledAt)
        }
    }

    nonisolated func logInputEvent(_ message: String) { tvStreamDebug("[TVStream] input: \(message)") }
}
