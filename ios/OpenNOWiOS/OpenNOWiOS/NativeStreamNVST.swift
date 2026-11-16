import CoreMedia
import CoreVideo
import Foundation
import WebRTC

struct NativeStreamVideoLiveness {
    enum Action: Equatable { case none, requestKeyframe, failed }
    private var lastProgressAt: UInt64
    private var lastDecoded: UInt64 = 0
    private var lastRequestAt: UInt64?

    init(now: UInt64) { lastProgressAt = now }

    mutating func observe(decoded: UInt64, now: UInt64) -> Action {
        if decoded > lastDecoded {
            lastDecoded = decoded
            lastProgressAt = now
            lastRequestAt = nil
            return .none
        }
        let age = now >= lastProgressAt ? now - lastProgressAt : 0
        if age >= 20_000_000_000 { return .failed }
        guard age >= 1_000_000_000 else { return .none }
        if let lastRequestAt, now >= lastRequestAt, now - lastRequestAt < 1_000_000_000 { return .none }
        lastRequestAt = now
        return .requestKeyframe
    }
}

/// A PLI on an unopened feedback channel can be discarded without an error. The
/// host also accepts an explicit IDR command on its reliable control channel.
enum NativeStreamKeyframeRecovery {
    @discardableResult
    static func request(sendControl: (NvstControlCommand) -> Bool, sendUDP: () -> Void) -> Bool {
        let sent = sendControl(.idrRequest())
        if !sent { sendUDP() }
        return sent
    }
}

struct NativeStreamNVSTSample: Sendable {
    let received: UInt64
    let decoded: UInt64
    let bytes: UInt64
    let lost: UInt64
    let packets: UInt64
    let resolution: String?
    let decodeMilliseconds: Double
    let pingMilliseconds: Double?
    let jitterMilliseconds: Double
    let hardware: Bool
    let pixelFormat: String
    let bitstream: String
    let detail: String
}

/// A protocol keeps the iOS 17 hardware API isolated from the app's iOS 16 deployment target.
protocol NativeStreamNVSTTransport: AnyObject, Sendable {
    func start() async throws
    func close() async
    func send(_ data: Data) async -> Bool
    func setAudioMuted(_ muted: Bool) async
}

@available(iOS 17.0, *)
actor NativeStreamNVST: NativeStreamNVSTTransport {
    private let allocation: ActiveSession
    private let settings: AppSettings
    private let profile: StreamVideoProfile
    private let codec: NativeStreamVideoCodec
    private let displayFPS: Int
    private let onFrame: @Sendable (RTCVideoFrame) -> Void
    private let onSample: @Sendable (NativeStreamNVSTSample) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let onTermination: @Sendable (NvstSeatTermination) -> Void
    private let onHaptics: @Sendable ([NvstHapticEvent]) -> Void
    private let onProgress: @Sendable (NvstRtspStage) -> Void
    /// Receives the receiver's, the decode queue's and the decoder's own event lines (a gap given
    /// up, a queue resync, a rejected frame). Nil keeps them silent.
    private let onDiagnostic: (@Sendable (String) -> Void)?
    private let clock = NvstSessionClock()
    private var reserver: NvstLocalBundleReserver?
    private var rtsp: NvstRtspSession?
    private var receiver: NvstMjolnirReceiver?
    private var bundle: NvstNativeBundle?
    private var decoder: NvstVideoToolboxDecoder?
    private var pipeline: NvstVideoPipeline?
    private let feedback = NvstFeedbackSender()
    private var stopped = false
    private var bundleGeneration: UInt64 = 0
    private var preparationError: Error?
    private var sampling: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var qos: Task<Void, Never>?
    private var inputSequence: UInt16 = 0
    private var gamepadSequences: [UInt16: UInt16] = [:]
    private var registeredBitmap: UInt16 = NvstGamepadPacket.connectedBitmap
    /// What the seat's DESCRIBE said about HID devices; nil until negotiated, or when it said nothing.
    private(set) var seatHidCapability: NvstHidPassthrough.SeatCapability?
    /// HID devices the seat has been told about, and each one's report counter.
    private var announcedHidDevices: Set<UInt8> = []
    private var hidSequences: [UInt8: UInt16] = [:]
    private var hidOutputReportsLogged = 0
    /// DualSense pads announced as themselves, by request id, with the device id the seat gave each.
    private var dualSenseDevices = NvstHidPassthrough.DeviceTable()
    private var onDualSenseRoute: (@Sendable (_ gamepadIndex: Int, _ accepted: Bool) -> Void)?
    private var onDualSenseOutput: (@Sendable (_ gamepadIndex: Int, NvstHidPassthrough.DualSense.Output) -> Void)?
    private var activatedInput = false
    private var qosSequence: UInt32 = 0
    private var lastQosBytes: UInt64 = 0
    private var lastDelay: UInt32 = 0
    private var lastRtpStatsFrame: UInt64 = 0
    private var lastControlStatsAt: Date?
    private var lastKeyframeRequestAt: Date?
    private var keyframeRequests = 0
    private var controlKeyframeRequests = 0
    private var udpKeyframeRequests = 0
    private var videoLiveness = NativeStreamVideoLiveness(now: DispatchTime.now().uptimeNanoseconds)
    private var didFinish = false
    private var touchPacketsSent = 0
    private var touchRecordsSent = 0
    private var touchSendFailures = 0

    init(allocation: ActiveSession, settings: AppSettings, profile: StreamVideoProfile,
         codec: NativeStreamVideoCodec, displayFPS: Int,
         onFrame: @escaping @Sendable (RTCVideoFrame) -> Void,
         onSample: @escaping @Sendable (NativeStreamNVSTSample) -> Void,
         onFailure: @escaping @Sendable (String) -> Void,
         onTermination: @escaping @Sendable (NvstSeatTermination) -> Void,
         onHaptics: @escaping @Sendable ([NvstHapticEvent]) -> Void,
         onProgress: @escaping @Sendable (NvstRtspStage) -> Void,
         onDiagnostic: (@Sendable (String) -> Void)? = nil) {
        self.allocation = allocation; self.settings = settings; self.profile = profile
        self.codec = codec; self.displayFPS = displayFPS
        self.onFrame = onFrame; self.onSample = onSample; self.onFailure = onFailure; self.onHaptics = onHaptics
        self.onTermination = onTermination
        self.onProgress = onProgress
        self.onDiagnostic = onDiagnostic
    }

    func start() async throws {
        guard !stopped else { throw CancellationError() }
        let endpoints = allocation.nativeRtspsEndpoints ?? []
        guard !endpoints.isEmpty else { throw NvstRtspNegotiationError.missingEndpoint }
        clock.start()
        let reserver = NvstLocalBundleReserver(bundleProvider: { [weak self] handoff, micOffered in
            await self?.prepareBundle(handoff: handoff, microphoneOffered: micOffered)
        })
        self.reserver = reserver
        let color = StreamSettingsResolver.colorQuality(for: settings).rawValue
        let input = NvstRtspNegotiationInput(sessionID: allocation.id, rtspsEndpoints: endpoints,
            resolution: profile.resolutionString, fps: profile.fps, codec: codec == .h265 ? "HEVC" : codec.rawValue,
            bitrateKbps: profile.maxBitrateKbps, maximumBitrateKbps: profile.maxBitrateKbps,
            colorQuality: color, hdrEnabled: settings.hdrEnabled, audioChannelCount: 2, rtcpOnSctp: true,
            disablesOwdCongestionControl: false, vsyncMode: .adaptive,
            announceOverrides: [("x-nv-vqos[0].dfc.enable", "0")])
        do {
            let negotiated = try await NvstRtspNegotiator(reserver: reserver, logger: onDiagnostic, onProgress: onProgress).negotiate(input,
                onVideoReady: { [weak self] handoff in
                    guard let self else { throw CancellationError() }
                    try await self.startVideo(handoff)
                }, onAnnounceReady: { [weak self] _ in await self?.punchBeforePlay() })
            if stopped || didFinish || Task.isCancelled {
                await negotiated.release("cancelled")
                throw CancellationError()
            }
            rtsp = negotiated
            seatHidCapability = negotiated.hidCapability
            if let preparationError { throw preparationError }
            videoLiveness = NativeStreamVideoLiveness(now: DispatchTime.now().uptimeNanoseconds)
            sampling = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sample()
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
        } catch {
            await close()
            throw error
        }
    }

    /// Who hears about a DualSense announced as itself: whether the seat took it, and what the
    /// game then writes to it.
    func setDualSenseHandlers(onRoute: @escaping @Sendable (_ gamepadIndex: Int, _ accepted: Bool) -> Void,
                              onOutput: @escaping @Sendable (_ gamepadIndex: Int, NvstHidPassthrough.DualSense.Output) -> Void) {
        onDualSenseRoute = onRoute
        onDualSenseOutput = onOutput
    }

    private func prepareBundle(handoff: NVSTVideoHandoff, microphoneOffered: Bool) async -> NvstBundleReservation? {
        guard !stopped else { return nil }
        do {
            let nativeBundle = NvstNativeBundle(handoff: handoff, identity: try NvstDtlsIdentity(), logger: nil)
            bundle = nativeBundle
            let generation = bundleGeneration
            feedback.configure(channelWriter: { [weak nativeBundle] data in _ = nativeBundle?.sendFeedback(data) },
                               senderSSRC: NvstVideoReceiver.clientSSRC, mediaSSRC: 0)
            nativeBundle.onControlChannelOpen = { [weak self] in Task { await self?.ifCurrent(generation) { $0.controlOpened() } } }
            nativeBundle.onPartiallyReliableControlOpen = { [weak self] in Task { await self?.ifCurrent(generation) { $0.qosOpened() } } }
            nativeBundle.onFeedbackChannelOpen = { [weak self] in Task { await self?.ifCurrent(generation) { $0.feedbackOpened() } } }
            nativeBundle.onInputProtocolNegotiated = { [weak self] _ in Task { await self?.ifCurrent(generation) { $0.activateInput() } } }
            nativeBundle.onSeatTermination = { [weak self] event in
                Task { await self?.ifCurrent(generation) { $0.terminate(event) } }
            }
            nativeBundle.onFailure = { [weak self] reason in Task { await self?.ifCurrent(generation) { $0.fail(reason) } } }
            nativeBundle.onHapticEvents = { [weak self] events in Task { await self?.ifCurrent(generation) { $0.onHaptics(events) } } }
            nativeBundle.onHidOutputReport = { [weak self] report in Task { await self?.ifCurrent(generation) { $0.hidOutput(report) } } }
            nativeBundle.onHidChangeResponse = { [weak self] response in Task { await self?.ifCurrent(generation) { $0.hidChangeResponse(response) } } }
            // The host's native bundle must offer the mic; legacy mic carriage is not announced.
            let mic = microphoneOffered && settings.keepMicEnabled
                ? NvstNativeBundle.MicrophoneSetup(volume: 1, initiallyEnabled: true) : nil
            let identity = try await nativeBundle.prepare(microphone: mic, audioChannelCount: 2)
            guard !stopped else { nativeBundle.close(); return nil }
            nativeBundle.setRemoteAudioMuted(settings.streamerPreferences.audioMuted)
            pipeline?.attach(bundle: nativeBundle)
            return NvstBundleReservation(bundlePort: identity.bundlePort, mjolnirPort: handoff.mjolnirUDPPort ?? handoff.clientUDPPort,
                localAddress: identity.localAddress, iceCredentials: reserver?.localIceCredentials,
                dtlsFingerprint: identity.dtlsFingerprint, microphoneNegotiated: nativeBundle.microphoneNegotiation.negotiated,
                microphoneSenderSsrc: nativeBundle.microphoneNegotiation.senderSsrc)
        } catch { preparationError = error; return nil }
    }

    private func startVideo(_ handoff: NVSTVideoHandoff) throws {
        guard !stopped else { throw CancellationError() }
        if let preparationError { throw preparationError }
        // Video must be armed before ANNOUNCE. The bundle identity is prepared during ANNOUNCE,
        // then attached to this pipeline before PLAY begins.
        bundleGeneration &+= 1
        receiver?.stop(); pipeline?.stop(); decoder?.invalidate()
        bundle?.close(); bundle = nil
        keepalive?.cancel(); keepalive = nil; qos?.cancel(); qos = nil
        feedback.stop(); activatedInput = false
        preparationError = nil; lastQosBytes = 0; lastDelay = 0; qosSequence = 0
        lastKeyframeRequestAt = nil
        keyframeRequests = 0; controlKeyframeRequests = 0; udpKeyframeRequests = 0
        lastRtpStatsFrame = 0; lastControlStatsAt = nil; gamepadSequences.removeAll()

        let decoder = NvstVideoToolboxDecoder(codec: handoff.codec,
            requiresTenBit444: StreamSettingsResolver.colorQuality(for: settings) == .tenBit444)
        self.decoder = decoder
        if let onDiagnostic { decoder.onDecodeFailure = { _, message in onDiagnostic(message) } }
        let callback = onFrame
        decoder.onPixelBuffer = { pixelBuffer, time, _ in
            // Keep the zero-copy P010 surface and its transfer attachments for the iOS HDR renderer.
            let ns = Int64(clamping: Int((CMTimeGetSeconds(time) * 1_000_000_000).rounded()))
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: ns)
            frame.timeStamp = Int32(truncatingIfNeeded: CMTimeConvertScale(time, timescale: 90_000, method: .default).value)
            callback(frame)
        }
        let pipeline = NvstVideoPipeline(decoder: decoder, clock: clock,
            frameTimeMicroseconds: UInt32(1_000_000 / max(1, profile.fps)),
            displayVsyncMicroseconds: UInt32(1_000_000 / max(1, displayFPS)),
            logger: onDiagnostic, mediaSink: nil,
            onKeyframeNeeded: { [weak self] in Task { await self?.requestKeyframe() } },
            onFatalDecodeError: { [weak self] reason in
                Task { await self?.fail(reason) }
            })
        self.pipeline = pipeline
        pipeline.attach(bundle: bundle)
        let descriptor = reserver?.takeMjolnirDescriptor() ?? -1
        let receiver = try NvstMjolnirReceiver(handoff: handoff, sendsReceiverReports: false, existingDescriptor: descriptor)
        self.receiver = receiver
        receiver.onAccessUnit = { unit in
            pipeline.submit(unit)
        }
        receiver.onRecoveryNeeded = { [weak self] _ in Task { await self?.requestKeyframe() } }
        receiver.onRetransmissionWanted = { sequences in pipeline.requestRetransmission(of: sequences) }
        receiver.onDiagnostic = onDiagnostic
        feedback.setReportProvider { [weak receiver] in receiver?.receiverReportBlock() }
        try receiver.start()
    }

    private func punchBeforePlay() async {
        receiver?.beginHolePunch()
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private func ifCurrent(_ generation: UInt64, _ action: @Sendable (isolated NativeStreamNVST) -> Void) {
        guard !stopped, generation == bundleGeneration else { return }
        action(self)
    }

    private func controlOpened() {
        guard !stopped, keepalive == nil else { return }
        _ = bundle?.sendControl(.windowStateChange())
        _ = bundle?.sendControl(.systemStateChange())
        requestKeyframe()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendKeepalive()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }

    private func sendKeepalive() {
        guard !stopped else { return }
        _ = bundle?.sendControl(.pingBackAck(streamValue: UInt32(truncatingIfNeeded: receiver?.feedbackCounters.framesEmitted ?? 0)))
    }

    private func feedbackOpened() {
        guard !stopped else { return }
        if let ssrc = receiver?.stats.boundSSRC { feedback.updateMediaSSRC(ssrc) }
        feedback.start()
    }

    private func qosOpened() {
        guard !stopped, qos == nil else { return }
        qos = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendQos()
                do { try await Task.sleep(nanoseconds: UInt64(NvstQosReport.interval * 1_000_000_000)) } catch { return }
            }
        }
    }

    private func sendQos() {
        guard !stopped, let bundle, let receiver else { return }
        let counters = receiver.feedbackCounters
        let stats = receiver.stats
        qosSequence &+= 1
        let delay = UInt32(clamping: Int(Double(stats.lastJitter) * 1_000_000 / 90_000))
        let delta = counters.bytesReceived >= lastQosBytes ? counters.bytesReceived - lastQosBytes : 0
        let report = NvstQosReport(sequence: qosSequence, framesReceived: UInt32(truncatingIfNeeded: counters.framesEmitted),
            bytesReceived: UInt32(truncatingIfNeeded: counters.bytesReceived),
            linkCapabilityKbps: UInt16(clamping: max(Int(NvstQosReport.defaultLinkCapabilityKbps), profile.maxBitrateKbps)),
            rtpTimestamp: counters.lastRtpTimestamp, previousBytesReceived: UInt32(truncatingIfNeeded: lastQosBytes),
            delayMicroseconds: delay, delayTrendMicroseconds: delay > lastDelay ? delay - lastDelay : lastDelay - delay,
            intervalBits: UInt32(clamping: delta * 8), isWarmedUp: clock.elapsedMicroseconds() >= 1_900_000)
        _ = bundle.sendPartiallyReliableControl(report.command)
        lastQosBytes = counters.bytesReceived; lastDelay = delay
        if stats.framesEmitted >= lastRtpStatsFrame + NvstRtpStatsReport.frameInterval {
            lastRtpStatsFrame = stats.framesEmitted
            let frame = UInt32(truncatingIfNeeded: stats.framesEmitted)
            let report = NvstRtpStatsReport(frameNumber: frame, totalReceivedPackets: stats.authenticatedPackets,
                outOfOrderPackets: UInt32(clamping: stats.outOfOrderPackets), dropEvents: UInt32(clamping: stats.recoveries),
                latePackets: UInt32(clamping: stats.latePackets), droppedPackets: UInt32(clamping: stats.droppedPackets),
                recoveredPackets: UInt32(clamping: stats.recoveredPackets), maxDropBurstLength: stats.maxLossBurst,
                maxWaitingQueueDepth: stats.maxReorderDepth, duplicatePackets: UInt32(clamping: stats.duplicatePackets),
                micChatSentDataBytes: bundle.microphoneSentBytes)
            _ = bundle.sendPartiallyReliableControl(report.command)
            _ = bundle.sendPartiallyReliableControl(NvstRtpNackStatsReport(frameNumber: frame,
                nackRequestsSent: UInt32(clamping: stats.nack.requestsSent),
                nackedPacketsRequested: UInt32(clamping: stats.nack.packetsRequested),
                nackedPacketsReceived: UInt32(clamping: stats.nack.packetsReceived),
                nackedPacketsUtilized: UInt32(clamping: stats.nack.packetsReceived),
                nackedPacketsRetried: UInt32(clamping: stats.nack.packetsRetried)).command)
        }
        if lastControlStatsAt.map({ Date().timeIntervalSince($0) >= NvstControlChannelStatsReport.transmitInterval }) ?? true {
            let stats = bundle.controlChannelStats
            _ = bundle.sendPartiallyReliableControl(NvstControlChannelStatsReport(timestampMicroseconds: clock.elapsedMicroseconds(),
                totalMessagesSent: stats.totalSent, totalMessagesFailed: stats.totalFailed, totalBytesSent: stats.totalBytes,
                commands: stats.commands).command)
            lastControlStatsAt = Date()
        }
    }

    private func activateInput() {
        guard !stopped, !activatedInput, let bundle, bundle.isInputReady else { return }
        activatedInput = true
        _ = bundle.sendControl(NvstInputActivation.enableInput(counter: 1, isEnabled: false))
        _ = bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: clock.elapsedMicroseconds(), connectedBitmap: registeredBitmap))
        _ = bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: true))
        _ = bundle.sendControl(NvstInputActivation.mimicRemoteCursor(isEnabled: true))
        _ = bundle.sendControl(.windowStateChange()); _ = bundle.sendControl(.systemStateChange())
        _ = bundle.sendControl(NvstInputActivation.enableInput(counter: UInt32(clamping: (pipeline?.snapshot.frameAcksSent ?? 0) + 1)))
        let haptics = NvstRemoteInput.framed(NvstRemoteInput.hapticsState(enabled: true),
            framing: .enveloped, sequence: inputSequence, timestampMicroseconds: clock.elapsedMicroseconds())
        let hapticsSent = bundle.sendControl(NvstControlCommand(code: .remoteInput, payload: haptics))
        NativeStreamRumbleDiagnostics.shared.record("nvstEnableSent", details: ["enableSendAccepted": String(hapticsSent)])
    }

    func send(_ data: Data) -> Bool {
        guard !stopped, activatedInput, let bundle else { return false }
        inputSequence &+= 1
        do {
            let outputs = try NativeStreamNVSTInput.translate(data, timestamp: clock.elapsedMicroseconds(), sequence: inputSequence)
            var sent = true
            for output in outputs {
                switch output {
                case .heartbeat: break // NVST's control keepalive already maintains liveness.
                case .control(let command): sent = bundle.sendControl(command) && sent
                case .touch(let command, let records):
                    let accepted = bundle.sendControl(command)
                    if accepted {
                        touchPacketsSent += 1
                        touchRecordsSent += records
                    } else {
                        touchSendFailures += 1
                    }
                    sent = accepted && sent
                case .gamepad(let pad):
                    if pad.connectedBitmap != registeredBitmap {
                        registeredBitmap = pad.connectedBitmap
                        _ = bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: clock.elapsedMicroseconds(), connectedBitmap: registeredBitmap))
                    }
                    let seq = (gamepadSequences[pad.gamepadIndex] ?? 0) &+ 1
                    gamepadSequences[pad.gamepadIndex] = seq
                    let sequenced = NvstGamepadPacket(sequence: seq, timestampMicroseconds: pad.timestampMicroseconds,
                        buttons: pad.buttons, leftTrigger: pad.leftTrigger, rightTrigger: pad.rightTrigger,
                        leftStickX: pad.leftStickX, leftStickY: pad.leftStickY, rightStickX: pad.rightStickX, rightStickY: pad.rightStickY,
                        gamepadIndex: pad.gamepadIndex, connectedBitmap: pad.connectedBitmap)
                    sent = bundle.sendInput(try sequenced.command.encoded) && sent
                case .hidReport(let report):
                    sent = try sendHid(report, on: bundle) && sent
                case .hidChange(let change):
                    if let index = NvstHidPassthrough.DualSense.gamepadIndex(requestId: change.deviceId) {
                        sent = sendDualSenseChange(change, gamepadIndex: index, on: bundle) && sent
                        break
                    }
                    // An add is sent with the device's first report, so only a removal the seat
                    // knows about travels on its own.
                    guard change.change == .removed, announcedHidDevices.remove(change.deviceId) != nil else { break }
                    hidSequences[change.deviceId] = nil
                    sent = sendHidChange(change, on: bundle) && sent
                }
            }
            return sent
        } catch { return false }
    }

    private func sendHidChange(_ change: NvstHidPassthrough.ChangeEvent, on bundle: NvstNativeBundle) -> Bool {
        let accepted = bundle.sendControl(NvstControlCommand(code: .remoteInput, payload: NvstRemoteInput.framed(
            change.packet, framing: .enveloped, sequence: inputSequence, timestampMicroseconds: clock.elapsedMicroseconds())))
        NSLog("[OpenNOW] hid device %d %@ sent=%d", Int(change.deviceId), change.change == .added ? "added" : "removed", accepted ? 1 : 0)
        return accepted
    }

    /// A pad sent as a HID device is not also a gamepad: the bitmap goes out without it first.
    private func unregisterGamepad(index: Int, on bundle: NvstNativeBundle) {
        let padBits = UInt16(1 << index) | UInt16(1 << (index + 8))
        guard registeredBitmap & padBits != 0 else { return }
        registeredBitmap &= ~padBits
        _ = bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: clock.elapsedMicroseconds(), connectedBitmap: registeredBitmap))
    }

    /// How long the seat gets to answer a DualSense announcement before the pad falls back.
    private static let dualSenseAnswerTimeoutNanoseconds: UInt64 = 3_000_000_000

    /// A DualSense announced as itself, or taken away again. The bridge names the pad by its
    /// request id either way; a removal goes out under the id the seat gave it. An announcement
    /// the seat does not answer in time counts as refused.
    private func sendDualSenseChange(_ change: NvstHidPassthrough.ChangeEvent, gamepadIndex index: Int, on bundle: NvstNativeBundle) -> Bool {
        let requestId = change.deviceId
        guard change.change == .added else {
            guard let seatId = dualSenseDevices.remove(request: requestId) else { return true }
            return sendHidChange(NvstHidPassthrough.DualSense.removalEvent(deviceId: seatId), on: bundle)
        }
        guard !dualSenseDevices.isAnnounced(requestId) else { return true }
        unregisterGamepad(index: index, on: bundle)
        dualSenseDevices.request(requestId)
        let generation = bundleGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.dualSenseAnswerTimeoutNanoseconds)
            await self?.ifCurrent(generation) { $0.dualSenseAnswerTimedOut(requestId: requestId, gamepadIndex: index) }
        }
        return sendHidChange(change, on: bundle)
    }

    private func dualSenseAnswerTimedOut(requestId: UInt8, gamepadIndex: Int) {
        guard dualSenseDevices.isAnnounced(requestId), dualSenseDevices.seatId(forRequest: requestId) == nil else { return }
        _ = dualSenseDevices.remove(request: requestId)
        NSLog("[OpenNOW] hid dualsense request %d unanswered", Int(requestId))
        onDualSenseRoute?(gamepadIndex, false)
    }

    private func hidChangeResponse(_ response: NvstHidPassthrough.ChangeResponse) {
        NSLog("[OpenNOW] hid change response request=%d status=%d flags=%x device=%d", Int(response.requestId), Int(response.status),
              Int(response.flags), Int(response.deviceId))
        guard let index = NvstHidPassthrough.DualSense.gamepadIndex(requestId: response.requestId) else { return }
        guard let accepted = dualSenseDevices.resolve(response) else {
            // Nobody is waiting for this pad any more: do not leave it attached on the seat.
            if response.isAccepted, dualSenseDevices.requestId(forSeat: response.deviceId) == nil, let bundle {
                _ = sendHidChange(NvstHidPassthrough.DualSense.removalEvent(deviceId: response.deviceId), on: bundle)
            }
            return
        }
        onDualSenseRoute?(index, accepted)
    }

    /// One report for a HID pad. A DualSense announced as itself stays silent until the seat has
    /// named it and then reports under the seat's id. A synthesized pad's first report announces
    /// it in the official client's order: the gamepad bitmap without it, then the HID add, then
    /// reports.
    private func sendHid(_ report: NvstHidPassthrough.Report, on bundle: NvstNativeBundle) throws -> Bool {
        var report = report
        if NvstHidPassthrough.DualSense.gamepadIndex(requestId: report.deviceId) != nil {
            guard let seatId = dualSenseDevices.seatId(forRequest: report.deviceId) else { return true }
            report = NvstHidPassthrough.Report(deviceId: seatId, kind: report.kind, reportType: report.reportType, data: report.data)
        } else {
            guard let index = NvstHidPassthrough.SynthesizedDualShock4.gamepadIndex(deviceId: report.deviceId) else { return false }
            if announcedHidDevices.insert(report.deviceId).inserted {
                unregisterGamepad(index: index, on: bundle)
                _ = sendHidChange(NvstHidPassthrough.SynthesizedDualShock4.changeEvent(gamepadIndex: index, connected: true), on: bundle)
            }
        }
        guard seatHidCapability?.usesPartiallyReliableTransfer(deviceId: report.deviceId) == true else {
            return bundle.sendControl(report.command(sequence: nil, timestampMicroseconds: clock.elapsedMicroseconds()))
        }
        let sequence = (hidSequences[report.deviceId] ?? 0) &+ 1
        hidSequences[report.deviceId] = sequence
        return bundle.sendInput(try report.command(sequence: sequence, timestampMicroseconds: clock.elapsedMicroseconds()).encoded)
    }

    /// A HID pad has no haptic command of its own: the game's rumble arrives as the pad's output
    /// report. A DualSense's report also carries its trigger effects, and the seat may ask it
    /// for a feature report, which is answered here.
    private func hidOutput(_ report: NvstHidPassthrough.Report) {
        if hidOutputReportsLogged < 5 {
            hidOutputReportsLogged += 1
            NSLog("[OpenNOW] hid output device=%d type=%d bytes=%d head=%@", Int(report.deviceId), Int(report.reportType), report.data.count,
                  report.data.prefix(12).map { String(format: "%02x", $0) }.joined())
        }
        if let requestId = dualSenseDevices.requestId(forSeat: report.deviceId),
           let index = NvstHidPassthrough.DualSense.gamepadIndex(requestId: requestId) {
            if let answer = NvstHidPassthrough.DualSense.response(toGetReport: report) {
                _ = bundle?.sendControl(answer.command(sequence: nil, timestampMicroseconds: clock.elapsedMicroseconds()))
            } else if let output = NvstHidPassthrough.DualSense.output(in: report) {
                onDualSenseOutput?(index, output)
            }
            return
        }
        guard let rumble = NvstHidPassthrough.SynthesizedDualShock4.rumble(in: report) else { return }
        onHaptics([rumble])
    }

    private func requestKeyframe() {
        guard !stopped, lastKeyframeRequestAt.map({ Date().timeIntervalSince($0) >= 0.25 }) ?? true else { return }
        lastKeyframeRequestAt = Date()
        keyframeRequests += 1
        let controlSent = NativeStreamKeyframeRecovery.request(
            sendControl: { bundle?.sendControl($0) ?? false },
            sendUDP: { receiver?.requestKeyframe() })
        if controlSent { controlKeyframeRequests += 1 }
        else { udpKeyframeRequests += 1 }
        if bundle?.isFeedbackChannelOpen == true {
            if let ssrc = receiver?.stats.boundSSRC { feedback.updateMediaSSRC(ssrc) }
            try? feedback.sendKeyframeRequestNow()
            feedback.requestKeyframe()
        }
    }

    private func sample() async {
        guard !stopped, let receiver, let decoder, let pipeline else { return }
        let stats = receiver.stats
        if let ssrc = stats.boundSSRC { feedback.updateMediaSSRC(ssrc) }
        let decoded = decoder.decodedFrameCount
        switch videoLiveness.observe(decoded: decoded, now: DispatchTime.now().uptimeNanoseconds) {
        case .none: break
        case .requestKeyframe: requestKeyframe()
        case .failed:
            fail(bundle?.isControlChannelOpen == true
                ? "Native NVST video stopped arriving or decoding. Switch off the experimental receiver to use the standard connection."
                : "Native NVST control did not connect. Switch off the experimental receiver to use the standard connection.")
            return
        }
        let counters = receiver.feedbackCounters
        var ping = receiver.roundTripMilliseconds
        if ping < 0, let rtsp { ping = await rtsp.controlRoundTripMilliseconds() }
        guard !stopped else { return }
        let state = pipeline.snapshot
        let detail = "native NVST hardware=\(decoder.isHardwareAccelerated) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) resolution=\(decoder.decodedResolution ?? "pending") output=\(decoder.outputPixelFormatName) bitstream=\(decoder.bitstreamFormat?.summary ?? "pending") requestedColor=\(StreamSettingsResolver.colorQuality(for: settings).rawValue) requestedHDR=\(settings.hdrEnabled) sessions=\(decoder.sessionCreationCount) failed=\(decoder.failedFrameCount) errors=\(decoder.failureStatusSummary) decoderStages=\(decoder.stageTimingSummary) recovery[requests=\(keyframeRequests) control=\(controlKeyframeRequests) udp=\(udpKeyframeRequests) keyframes=\(stats.keyframesEmitted) feedback=\(bundle?.isFeedbackChannelOpen == true)] buffer=\(receiver.receiveBufferBytes) ack=\(state.frameAcksSent) pacing=\(state.pacingReportsSent) fec=\(stats.recoveredPackets) nack[requests=\(stats.nack.requestsSent) packets=\(stats.nack.packetsRequested) resent=\(stats.nack.packetsReceived)] auth=\(stats.authenticatedPackets) \(state.timingSummary)"
        onSample(NativeStreamNVSTSample(received: counters.framesEmitted, decoded: decoded, bytes: counters.bytesReceived,
            lost: stats.finalizedLossPackets, packets: stats.authenticatedPackets, resolution: decoder.decodedResolution,
            decodeMilliseconds: state.decodeP50Milliseconds, pingMilliseconds: ping >= 0 ? ping : nil,
            jitterMilliseconds: Double(stats.lastJitter) / 90, hardware: decoder.isHardwareAccelerated,
            pixelFormat: decoder.outputPixelFormatName, bitstream: decoder.bitstreamFormat?.summary ?? "pending", detail: detail))
    }

    private func fail(_ reason: String) {
        guard !stopped, !didFinish else { return }
        didFinish = true
        onFailure(reason)
        Task { await self.close() }
    }

    private func terminate(_ event: NvstSeatTermination) {
        guard !stopped, !didFinish else { return }
        didFinish = true
        onTermination(event)
        Task { await self.close() }
    }

    func setAudioMuted(_ muted: Bool) { bundle?.setRemoteAudioMuted(muted) }

    func close() async {
        guard !stopped else { return }
        stopped = true
        bundleGeneration &+= 1
        sampling?.cancel(); sampling = nil
        keepalive?.cancel(); keepalive = nil
        qos?.cancel(); qos = nil
        feedback.stop()
        receiver?.stop(); receiver = nil
        pipeline?.stop(); pipeline?.attach(bundle: nil); pipeline = nil
        bundle?.close(); bundle = nil
        // Hardware teardown can wait for output callbacks; keep it off the main actor.
        decoder?.invalidate(); decoder = nil
        reserver?.release(); reserver = nil
        let session = rtsp; rtsp = nil
        await session?.release("iOS native transport closed")
    }
}
