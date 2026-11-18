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
    /// Called on the decoder's queue with the milliseconds from `markResume()` to the next frame.
    var onResumedFrame: (@Sendable (Double) -> Void)?
    private var resumedAt: UInt64?

    /// Times how long the picture takes to come back after the stream was suspended.
    func markResume() {
        lock.lock(); defer { lock.unlock() }
        resumedAt = DispatchTime.now().uptimeNanoseconds
    }

    init(layer: AVSampleBufferDisplayLayer) { renderer = layer.sampleBufferRenderer }

    func enqueue(_ frame: NativeStreamNVSTFrame) {
        lock.lock(); defer { lock.unlock() }
        if let resumedAt {
            self.resumedAt = nil
            onResumedFrame?(Double(DispatchTime.now().uptimeNanoseconds - resumedAt) / 1_000_000)
        }
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
    @Published private var menu = TVStreamMenu()
    /// Set while video plays in a display mode this app does not hold; the stream screen asks
    /// tvOS to match the TV to it.
    @Published private(set) var displayCriteria: AVDisplayCriteria?
    /// Seconds left on the "Still playing?" countdown; nil while someone is playing.
    @Published private(set) var idleSecondsLeft: Int?

    /// A short message over the game, cleared after a few seconds: slow wireless sound, Wi-Fi
    /// trouble, a controller running low.
    @Published private(set) var notice: String?
    /// Wi-Fi or Ethernet, for the connecting screen, the menu and the session report.
    @Published private(set) var networkKind: SessionNetworkKind = .unknown

    /// What the countdown ends in, as Settings chose it.
    var idleAction: StreamIdleAction { settings.streamIdleAction }

    var menuVisible: Bool { menu.visible }
    var selection: Int { menu.selection }
    /// The menu is asking whether to end the session, which closes the game on the host.
    var confirmingEnd: Bool { menu.confirmingEnd }
    var menuItems: [TVStreamMenuItem] { menu.items(in: menuContext) }

    private var menuContext: TVStreamMenu.Context {
        TVStreamMenu.Context(failed: failed, canRetry: canRetry, statsVisible: statsVisible,
            dualSense: GCController.controllers().contains { $0.extendedGamepad is GCDualSenseGamepad })
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
    private var foregroundObserver: NSObjectProtocol?
    /// Set while the app is away for a moment with the stream held open.
    private var suspendedAt: TimeInterval?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundGraceTask: Task<Void, Never>?
    /// How long a stream waits in the background for the player to come back. tvOS gives a
    /// background task about half a minute; the rest is left for closing the stream cleanly.
    private static let backgroundGrace: TimeInterval = 20
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
    /// Nil when Settings leaves idle streams alone.
    private var idleGuard: TVStreamIdleGuard?
    private var lastInputSignature: TVInputActivitySignature?
    private let networkMonitor = TVNetworkMonitor()
    private var wifiTrouble = TVWiFiTroubleDetector()
    private var audioRoute: TVAudioRoute?
    private var audioRouteObserver: NSObjectProtocol?
    /// The lowest battery level each player has been warned about this stream.
    private var batteryWarned: [Int: Int] = [:]
    private var noticeTask: Task<Void, Never>?
    private static let noticeDuration: Duration = .seconds(8)

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
        inputBridge.setMotionEnabled(settings.controllerMotionEnabled)
        inputBridge.onControllerHUDCommand = { [weak self] command in
            Task { @MainActor in self?.handleMenu(command) }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        inputBridge.attach()
        TVGameMaster.hold(.stream)
        UIApplication.shared.isIdleTimerDisabled = true
        networkMonitor.start { [weak self] kind in self?.networkChanged(kind) }
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAudioRoute(announce: true) }
        }
        if settings.streamIdleAction != .off {
            idleGuard = TVStreamIdleGuard(idleMinutes: settings.streamIdleMinutes,
                                          now: ProcessInfo.processInfo.systemUptime)
        }
        startMenuPolling()
        // A suspended app loses the stream's sockets. A short trip to the Home screen keeps the
        // stream open under a background task instead, so coming back is instant; a longer one
        // closes it, and the session keeps running on the host to be rejoined from the app.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteringForeground() }
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
        let audioChannels = StreamSettingsResolver.audioChannelCount(for: session, settings: settings)
        tvStreamDebug("[TVStream] audio output carries \(TVAudioOutput.channels) channels, asking the seat for \(audioChannels)"
            + (session.requestedAudioChannelCount == nil ? " (resolved now)" : " (as the session was requested)"))
        renderer.onResumedFrame = { milliseconds in
            TVStreamLog.note(String(format: "picture back %.0f ms after returning", milliseconds))
            tvStreamDebug(String(format: "[TVStream] resume: first frame %.0f ms after returning", milliseconds))
        }
        let transport = NativeStreamNVST(allocation: session, settings: settings, profile: profile, codec: codec,
            displayFPS: max(profile.fps, UIScreen.main.maximumFramesPerSecond),
            audioChannelCount: audioChannels,
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
        TVGameMaster.release(.stream)
        startTask?.cancel(); startTask = nil
        menuPoll?.invalidate(); menuPoll = nil
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        backgroundGraceTask?.cancel(); backgroundGraceTask = nil
        suspendedAt = nil
        // The background task, if any, lasts until the stream has been closed.
        let backgroundTask = backgroundTask
        self.backgroundTask = .invalid
        if let audioRouteObserver { NotificationCenter.default.removeObserver(audioRouteObserver) }
        audioRouteObserver = nil
        networkMonitor.stop()
        noticeTask?.cancel(); noticeTask = nil
        checkpointHistory(ended: true)
        inputBridge.detach()
        UIApplication.shared.isIdleTimerDisabled = false
        let transport = transport; self.transport = nil
        let renderer = renderer
        Task {
            await transport?.close(); renderer.flush()
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
    }

    /// The Home button, or anything else that sends the app away. A playing stream is held open,
    /// out of sight, for `backgroundGrace`; anything else is closed at once as before.
    private func enteredBackground() {
        guard !stopped, suspendedAt == nil else { return }
        guard videoActive, !failed, let transport else { leave(); return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "OpenNOW stream") { [weak self] in
            // The system is about to suspend the app: close now, and give the task back in time.
            MainActor.assumeIsolated {
                guard let self else { return }
                let task = self.backgroundTask
                self.backgroundTask = .invalid
                self.backgroundGraceExpired(reason: "background time ran out")
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
        guard task != .invalid else { leave(); return }
        backgroundTask = task
        suspendedAt = ProcessInfo.processInfo.systemUptime
        // Buttons held on the way out must not stay pressed in the game.
        inputBridge.setControllerHUDActive(true)
        Task { await transport.setSuspended(true) }
        let grace = min(Self.backgroundGrace, max(0, UIApplication.shared.backgroundTimeRemaining - 5))
        TVStreamLog.note(String(format: "stream held in background for up to %.0f s", grace))
        tvStreamDebug(String(format: "[TVStream] background: holding the stream for up to %.0f s", grace))
        backgroundGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            self?.backgroundGraceExpired(reason: "away longer than the grace period")
        }
    }

    private func backgroundGraceExpired(reason: String) {
        guard suspendedAt != nil, !stopped else { return }
        TVStreamLog.note("stream closed in background: \(reason)")
        tvStreamDebug("[TVStream] background: closing, \(reason)")
        leave()
    }

    /// Back from the Home screen in time: the picture returns with the next keyframe.
    private func enteringForeground() {
        guard let suspendedAt, !stopped, let transport else { return }
        self.suspendedAt = nil
        backgroundGraceTask?.cancel(); backgroundGraceTask = nil
        let away = ProcessInfo.processInfo.systemUptime - suspendedAt
        TVStreamLog.note(String(format: "stream resumed after %.1f s away", away))
        tvStreamDebug(String(format: "[TVStream] background: back after %.1f s, resuming", away))
        idleGuard?.noteActivity(at: ProcessInfo.processInfo.systemUptime)
        // Blocks buttons still held from before until they are let go, as when the menu closes.
        inputBridge.setControllerHUDActive(menu.visible)
        renderer.markResume()
        Task { await transport.setSuspended(false) }
        let task = backgroundTask
        backgroundTask = .invalid
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    func leave() { stop(); onClose() }

    /// With Match Content on, tvOS switches the TV to the dynamic range and frame rate a video asks for.
    private func videoFormatChanged(_ format: CMVideoFormatDescription, fps: Float) {
        guard !stopped else { return }
        let transfer = CMFormatDescriptionGetExtension(format,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        let hdr = transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
            || transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        // Decided on the video that arrives, not the HDR setting: a stream requested as HDR is often
        // SDR. When the display is held in a mode for this video (fixed in Settings, or a high-refresh
        // one) it is selected directly; the system's own mode matching stays at 60 Hz, so it is only
        // the fallback, and it is asked for SDR video too: a TV left in Dolby Vision or HDR10 then
        // returns to SDR for an SDR game instead of showing it tone-mapped.
        let modeHeld = TVDisplayMode.streamVideo(fps: Int(fps),
            width: Int(CMVideoFormatDescriptionGetDimensions(format).width), hdr: hdr)
        displayCriteria = modeHeld ? nil : AVDisplayCriteria(refreshRate: fps, formatDescription: format)
        tvStreamDebug("[TVStream] video format transfer=\(transfer ?? "none") hdr=\(hdr)")
    }

    func retry() { stop(); onRetry?() }

    private func update(_ sample: NativeStreamNVSTSample) {
        guard !stopped, !failed else { return }
        if sample.decoded > 0 {
            let firstFrame = !videoActive
            if firstFrame { tvStreamDebug("[TVStream] video active: \(sample.detail)") }
            videoActive = true
            // The stream's audio session is running by now, so the route is the one it plays on.
            if firstFrame { refreshAudioRoute(announce: true) }
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
            TVStreamFigure(label: "Sound", value: sample.soundText),
            TVStreamFigure(label: "Thermal", value: thermal.tvLabel),
            TVStreamFigure(label: "Network", value: networkKind == .unknown ? "–" : networkKind.label),
            TVStreamFigure(label: "Audio Output", value: audioRoute?.figure ?? "–"),
        ]
        let batteries = TVControllerBattery.all()
        if !batteries.isEmpty {
            figures.append(TVStreamFigure(label: batteries.count > 1 ? "Controllers" : "Controller",
                                          value: batteries.map(\.label).joined(separator: " · ")))
        }
        checkBatteries(batteries)
        if wifiTrouble.shouldReport(network: networkKind, lossPercent: reading.lossPercent, jitterMs: reading.jitterMs) {
            TVStreamLog.note("wifi trouble: loss=\(reading.lossPercent)% jitter=\(reading.jitterMs)ms")
            showNotice("Wi-Fi is dropping or delaying packets. An Ethernet cable usually keeps the stream steady.")
        }
        onRuntimeSample(StreamRuntimeSample(timestamp: now, pingMs: reading.pingMs, bitrateKbps: reading.bitrateKbps,
            jitterMs: reading.jitterMs, fps: reading.decodedFPS, receivedFps: reading.receivedFPS,
            decodedFps: reading.decodedFPS, decodeMs: reading.decodeMs, packetsLostDelta: reading.packetsLostDelta,
            packetsReceivedDelta: reading.packetsReceivedDelta, packetLossPercent: reading.lossPercent,
            resolution: reading.resolution, codec: codecLabel, networkKind: networkKind))
        checkpointHistory(ended: false)
        // Every second that has levels, not only the stats line's one in five: the meter is reset
        // by each sample, and an intermittent centre channel must not read as silent.
        if !sample.audioLevels.isEmpty {
            tvStreamDebug("[TVStream] audio \(sample.audioFormat ?? "pending") dBFS all/above200Hz per channel: \(sample.audioLevels)")
        }
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
        menu.setVisible(false)
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
        guard menu.visible != visible, !failed else { return }
        menu.setVisible(visible)
        // Releases the game's buttons while the menu owns the controller, and blocks held ones on return.
        inputBridge.setControllerHUDActive(visible)
    }

    /// Menu navigation from a game controller (via the input bridge) or the Siri Remote.
    func handleMenu(_ command: NativeStreamControllerHUDCommand) {
        guard !stopped, let action = menu.handle(command, in: menuContext) else { return }
        switch action {
        case .resume: setMenuVisible(false)
        case .setStatsVisible(let visible): setStatsVisible(visible)
        case .stepTriggerFeel(let item, let steps): stepTriggerFeel(item, by: steps)
        case .leave: leave()
        case .retry: retry()
        case .endSession: stop(); onEndSession?()
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
        pollIdle()
        let held = GCController.controllers().contains { $0.extendedGamepad?.buttonMenu.isPressed ?? false }
        menuHoldPolls = held ? menuHoldPolls + 1 : 0
        guard !stopped, menuHoldPolls == Self.menuHoldThreshold, menuItems.isEmpty else { return }
        setMenuVisible(true)
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func networkChanged(_ kind: SessionNetworkKind) {
        guard !stopped, kind != networkKind else { return }
        networkKind = kind
        TVStreamLog.note("network \(kind.label)")
        tvStreamDebug("[TVStream] network \(kind.label)")
    }

    /// Reads where the sound goes. A slow wireless output is pointed out when the stream starts on
    /// it or moves to it, not again for the same output.
    private func refreshAudioRoute(announce: Bool) {
        guard !stopped, let route = TVAudioRoute.current() else { return }
        let previous = audioRoute
        audioRoute = route
        guard route != previous else { return }
        TVStreamLog.note("audio route \(route.figure)")
        tvStreamDebug("[TVStream] audio route \(route.figure)")
        if announce, videoActive, previous?.name != route.name, let text = route.notice { showNotice(text) }
    }

    private func checkBatteries(_ batteries: [TVControllerBattery]) {
        for battery in batteries {
            guard let player = battery.player, let level = battery.warningLevel,
                  level < batteryWarned[player] ?? .max else { continue }
            batteryWarned[player] = level
            showNotice("Controller \(player) battery is at \(battery.percent ?? level)%.")
        }
    }

    /// Counts down a stream nobody is playing. The clock runs from the first frame, and any change
    /// in what the controllers, keyboard, mouse or remote are doing restarts it.
    private func pollIdle() {
        guard var idleGuard, !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let signature = TVInputActivitySignature.current()
        if signature != lastInputSignature || !videoActive || failed {
            lastInputSignature = signature
            idleGuard.noteActivity(at: now)
        }
        self.idleGuard = idleGuard
        switch idleGuard.phase(at: now) {
        case .active:
            if idleSecondsLeft != nil { idleSecondsLeft = nil }
        case .warning(let seconds):
            if idleSecondsLeft == nil { tvStreamDebug("[TVStream] idle: countdown started") }
            if idleSecondsLeft != seconds { idleSecondsLeft = seconds }
        case .expired:
            idleSecondsLeft = nil
            TVStreamLog.note("idle for \(settings.streamIdleMinutes) min; \(idleAction.rawValue)")
            tvStreamDebug("[TVStream] idle: \(idleAction.rawValue) after \(settings.streamIdleMinutes) min")
            switch idleAction {
            case .off: break
            case .leaveStream: leave()
            case .endSession: stop(); onEndSession?()
            }
        }
    }

    private func noteRemoteActivity() {
        idleGuard?.noteActivity(at: ProcessInfo.processInfo.systemUptime)
        idleSecondsLeft = nil
    }

    /// Siri Remote buttons, passed on by the stream screen as UIKit presses. GameController reports
    /// every clickpad click as Button A, ring clicks included, so it cannot tell Down from Select.
    func remotePressed(_ type: UIPress.PressType) {
        guard !stopped else { return }
        noteRemoteActivity()
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
            TVStreamFigure(label: "Sound", value: "5.1"),
            TVStreamFigure(label: "Thermal", value: ProcessInfo.processInfo.thermalState.tvLabel),
            TVStreamFigure(label: "Network", value: "Wi-Fi"),
            TVStreamFigure(label: "Audio Output", value: "HDMI · 18 ms"),
            TVStreamFigure(label: "Controllers", value: "P1 62% · P2 charging"),
        ]
        setMenuVisible(true)
    }

    /// `--opennow-stream-menu-preview=idle`: the "Still playing?" countdown over the game.
    func installNoticePreview() {
        videoActive = true
        notice = "AirPods Pro plays the sound about 182 ms late. Sound through the TV is in step with the picture."
    }

    func installIdlePreview() {
        videoActive = true
        idleSecondsLeft = 42
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
