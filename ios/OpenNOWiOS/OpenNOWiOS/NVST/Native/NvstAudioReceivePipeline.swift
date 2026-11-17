import Foundation

/// The game-audio receive path: SRTP in, interleaved PCM out.
///
/// Each stage already exists and is tested on its own — decryption, reordering, concealment
/// signalling, Opus decode — so this type's job is the ordering and the accounting between them.
/// The sequence it enforces is the one that matters: decrypt before reorder (a packet cannot be
/// ordered until its tag has been verified), and reorder before decode (Opus has no idea what order
/// frames arrived in).
///
/// What is decoded is the seat's decision, not the client's: a stream that asked for surround
/// starts `pending` and decodes nothing until the seat has named its layout, because a stereo
/// decoder on a surround stream plays noise.
public final class NvstAudioReceivePipeline: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var datagrams: UInt64 = 0
        public var authenticated: UInt64 = 0
        public var authenticationFailures: UInt64 = 0
        public var replayDrops: UInt64 = 0
        public var packetsDecoded: UInt64 = 0
        public var packetsLost: UInt64 = 0
        public var decodeFailures: UInt64 = 0
        public var concealedFrames: UInt64 = 0
        /// Frames that arrived as a repeat inside a later RED packet and were slotted back into
        /// their original position, so a loss never reached the decoder.
        public var recoveredPackets: UInt64 = 0
        public var malformedRedPackets: UInt64 = 0
        /// Everything that arrived on the socket, before any of it was judged.
        public var datagramBytes: UInt64 = 0
        /// Interleaved samples the decoder actually produced.
        public var decodedSamples: UInt64 = 0
        public var ssrc: UInt32?
    }

    public enum State: Equatable, Sendable {
        /// Surround was asked for and the seat has not said what it sends: payloads are dropped.
        case pending
        case decoding(NvstAudioLayout)
        /// No decoder could be built for the seat's layout; the session stays silent.
        case unavailable
    }

    /// The payload type the seat's redundant audio is wrapped in. The primary inside it is the
    /// codec's own type.
    public static let redundantPayloadType: UInt8 = 63
    /// How long a pending pipeline waits for the seat's layout once audio is arriving. The official
    /// client also treats a missing answer as stereo.
    public static let pendingTimeoutNanoseconds: UInt64 = 2_000_000_000

    public let framesPerPacket: Int
    /// Called once, off the pipeline's lock, when the wait ran out and stereo was chosen.
    public var onPendingTimeout: (@Sendable () -> Void)?

    private let srtp: NvstAudioSrtp
    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private var decoder: NvstOpusDecoder?
    private var currentState: State
    private var firstPendingAudioAt: UInt64?
    private var jitter: NvstAudioJitterBuffer
    private var counters = Counters()
    private var replayWindows: [UInt32: SrtpReplayWindow] = [:]
    private var bufferedSamples: [Float] = []
    private var sampleOffset = 0

    /// - Parameter layout: what to decode from the first packet on, or nil to wait for
    ///   `configure(layout:)`.
    public init(srtp: NvstAudioSrtp,
                framesPerPacket: Int = 240,
                layout: NvstAudioLayout? = .stereo,
                targetDepth: Int = 3,
                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws {
        self.srtp = srtp
        self.framesPerPacket = framesPerPacket
        self.now = now
        self.jitter = NvstAudioJitterBuffer(targetDepth: targetDepth)
        if let layout {
            decoder = try NvstOpusDecoder(layout: layout, framesPerPacket: framesPerPacket)
            currentState = .decoding(layout)
        } else {
            decoder = nil
            currentState = .pending
        }
    }

    public var snapshot: Counters { lock.withLock { counters } }
    public var state: State { lock.withLock { currentState } }
    /// The layout being decoded; nil while pending or unavailable.
    public var layout: NvstAudioLayout? {
        if case .decoding(let layout) = state { return layout }
        return nil
    }
    /// How long the emitted packets waited in the jitter buffer, and how many were emitted. The HUD
    /// divides one by the other for its A/V reading, exactly as it did over libwebrtc's counters.
    public var jitterBufferDwellSeconds: TimeInterval { lock.withLock { jitter.jitterBufferDelaySeconds } }
    public var jitterBufferEmittedCount: UInt64 { lock.withLock { jitter.jitterBufferEmittedCount } }

    /// Starts decoding `layout`, replacing whatever was decoded before; audio already buffered for
    /// the old layout is dropped. Throws when no decoder can be built, and the pipeline is then
    /// `unavailable`.
    public func configure(layout: NvstAudioLayout) throws {
        lock.lock()
        defer { lock.unlock() }
        try configureLocked(layout)
    }

    private func configureLocked(_ layout: NvstAudioLayout) throws {
        guard currentState != .decoding(layout) else { return }
        jitter.reset()
        bufferedSamples.removeAll(keepingCapacity: true)
        sampleOffset = 0
        firstPendingAudioAt = nil
        do {
            decoder = try NvstOpusDecoder(layout: layout, framesPerPacket: framesPerPacket)
            currentState = .decoding(layout)
        } catch {
            decoder = nil
            currentState = .unavailable
            throw error
        }
    }

    /// Verifies and queues one datagram. A packet that fails its tag is counted and discarded: it is
    /// indistinguishable from an attacker's, and either way it is not audio.
    ///
    /// A RED packet carries repeats of earlier frames ahead of the frame it was sent for, so the
    /// repeats are slotted back at the sequences they belong to. If one of those was lost, this is
    /// where it is recovered — the seat sent it twice precisely so that a single loss would not
    /// reach the decoder.
    public func ingest(_ datagram: Data) {
        if ingestLocked(datagram) { onPendingTimeout?() }
    }

    /// Returns true when this datagram ended the pending wait by choosing stereo.
    private func ingestLocked(_ datagram: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        counters.datagrams += 1
        counters.datagramBytes &+= UInt64(datagram.count)
        guard let header = NvstAudioRtpPacket.parse(datagram, tagLength: srtp.authenticationTagLength) else {
            counters.authenticationFailures += 1
            return false
        }
        var replayWindow = replayWindows[header.ssrc] ?? SrtpReplayWindow()
        let index = replayWindow.estimatedIndex(for: header.sequenceNumber)
        guard replayWindow.wouldAccept(index) else {
            counters.replayDrops += 1
            return false
        }
        let packet: NvstAudioRtpPacket
        let payload: Data
        do {
            (packet, payload) = try srtp.unprotect(datagram, rolloverCounter: UInt32(truncatingIfNeeded: index >> 16))
        } catch {
            counters.authenticationFailures += 1
            return false
        }
        guard replayWindow.accept(index) else { return false }
        replayWindows[packet.ssrc] = replayWindow
        counters.ssrc = packet.ssrc
        counters.authenticated += 1

        let timedOut = settlePendingLocked()
        guard decoder != nil else { return timedOut }
        guard packet.payloadType == Self.redundantPayloadType else {
            jitter.insert(sequenceNumber: packet.sequenceNumber, payload: payload)
            return timedOut
        }
        guard let blocks = NvstRedAudio.split(payload), let primary = blocks.last else {
            counters.malformedRedPackets += 1
            return timedOut
        }
        for repeatBlock in blocks.dropLast() {
            let framesBack = Int(repeatBlock.timestampOffset) / max(1, framesPerPacket)
            let sequence = packet.sequenceNumber &- UInt16(truncatingIfNeeded: framesBack)
            jitter.insert(sequenceNumber: sequence, payload: repeatBlock.payload)
            counters.recoveredPackets += 1
        }
        jitter.insert(sequenceNumber: packet.sequenceNumber, payload: primary.payload)
        return timedOut
    }

    /// Ends the wait for the seat's layout once audio has been arriving for long enough.
    private func settlePendingLocked() -> Bool {
        guard currentState == .pending else { return false }
        let time = now()
        let first = firstPendingAudioAt ?? time
        firstPendingAudioAt = first
        guard time >= first, time - first >= Self.pendingTimeoutNanoseconds else { return false }
        return (try? configureLocked(.stereo)) != nil
    }

    /// Emits the frames that are ready, in order, with a silent frame standing in for each packet
    /// that never arrived.
    ///
    /// Timing is what concealment has to preserve here: the caller is feeding a device that expects
    /// a fixed rate, so a gap must still consume its 5 ms. Opus's own packet-loss concealment would
    /// fill that gap with extrapolated audio rather than silence, but `AudioConverter` does not
    /// expose it, so silence is used and counted.
    public func pull() -> [Float] {
        lock.withLock {
            defer { bufferedSamples.removeAll(keepingCapacity: true); sampleOffset = 0 }
            return Array(bufferedSamples.dropFirst(sampleOffset)) + drain(jitter.advance())
        }
    }

    /// Up to `frames` frames for a reader set up for `channels` channels. A reader whose channel
    /// count is not the one being decoded gets nothing and consumes nothing, so a device that has
    /// not yet followed a layout change cannot knock the channels out of step.
    public func pull(frames: Int, channels: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard frames > 0, case .decoding(let layout) = currentState, layout.channels == channels else { return [] }
        if sampleOffset > 0 {
            bufferedSamples.removeFirst(sampleOffset)
            sampleOffset = 0
        }
        bufferedSamples.append(contentsOf: drain(jitter.advance()))
        let count = min(frames * channels, bufferedSamples.count)
        sampleOffset = count
        return Array(bufferedSamples.prefix(count))
    }

    /// Emits everything still held; the stream is ending, so nothing should be left behind.
    public func flush() -> [Float] {
        lock.withLock {
            defer { bufferedSamples.removeAll(keepingCapacity: true); sampleOffset = 0 }
            return Array(bufferedSamples.dropFirst(sampleOffset)) + drain(jitter.flush())
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        jitter.reset()
        replayWindows.removeAll()
        bufferedSamples.removeAll(keepingCapacity: true)
        sampleOffset = 0
    }

    private func drain(_ emissions: [NvstAudioJitterBuffer.Emission]) -> [Float] {
        guard let decoder else { return [] }
        var output: [Float] = []
        for emission in emissions {
            switch emission {
            case .payload(let payload):
                do {
                    if let decoded = try decoder.decode(payload) {
                        output.append(contentsOf: decoded)
                        counters.packetsDecoded += 1
                        counters.decodedSamples &+= UInt64(decoded.count)
                    }
                } catch {
                    counters.decodeFailures += 1
                    output.append(contentsOf: silence(channels: decoder.layout.channels))
                }
            case .lost:
                counters.packetsLost += 1
                counters.concealedFrames += UInt64(framesPerPacket)
                output.append(contentsOf: silence(channels: decoder.layout.channels))
            }
        }
        return output
    }

    private func silence(channels: Int) -> [Float] {
        [Float](repeating: 0, count: framesPerPacket * channels)
    }
}
