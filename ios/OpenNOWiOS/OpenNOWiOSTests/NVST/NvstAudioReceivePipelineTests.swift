import Foundation
import Testing
@testable import OpenNOWiOS

/// The audio receive path's handling of the seat's channel layout.
struct NvstAudioReceivePipelineTests {
    private static let key = Data(repeating: 0x11, count: 32)
    private static let salt = Data(repeating: 0x22, count: 12)

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        var now: UInt64 {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private func srtp() throws -> NvstAudioSrtp {
        try NvstAudioSrtp(masterKey: Self.key, masterSalt: Self.salt, profile: .aeadAes256Gcm8)
    }

    /// Sealed stereo Opus datagrams with consecutive sequence numbers, as the seat sends them.
    private func datagrams(_ count: Int) throws -> [Data] {
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: 240)
        var tone = [Float](repeating: 0, count: 240 * 2)
        for frame in 0..<240 {
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000)) * 0.5
            tone[frame * 2] = value
            tone[frame * 2 + 1] = value
        }
        var payload: Data?
        for _ in 0..<8 where payload == nil { payload = try encoder.encode(tone) }
        let opus = try #require(payload)
        let sender = try srtp()
        var packetizer = NvstAudioRtpPacketizer(ssrc: 1, payloadType: 111, initialSequenceNumber: 1, initialTimestamp: 0)
        return try (0..<count).map { _ in try sender.protect(packetizer.packet(payload: opus, framesPerPacket: 240)) }
    }

    @Test func aStereoPipelineDecodesAtOnce() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp())
        #expect(pipeline.state == .decoding(.stereo))
        for datagram in try datagrams(16) { pipeline.ingest(datagram) }
        #expect(!pipeline.pull().isEmpty)
    }

    @Test func aPendingPipelineAuthenticatesButPlaysNothing() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp(), layout: nil, now: { 0 })
        for datagram in try datagrams(16) { pipeline.ingest(datagram) }
        #expect(pipeline.state == .pending)
        #expect(pipeline.layout == nil)
        #expect(pipeline.snapshot.authenticated == 16)
        #expect(pipeline.snapshot.packetsDecoded == 0)
        #expect(pipeline.pull().isEmpty)
        #expect(pipeline.pull(frames: 240, channels: 2).isEmpty)
    }

    @Test func theSeatsLayoutStartsDecoding() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp(), layout: nil, now: { 0 })
        let all = try datagrams(32)
        for datagram in all.prefix(16) { pipeline.ingest(datagram) }
        try pipeline.configure(layout: .stereo)
        #expect(pipeline.state == .decoding(.stereo))
        for datagram in all.suffix(16) { pipeline.ingest(datagram) }
        #expect(!pipeline.pull().isEmpty)
    }

    @Test func withoutAnAnswerItFallsBackToStereoAfterTwoSeconds() throws {
        let clock = Clock()
        let fellBack = Flag()
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp(), layout: nil, now: { clock.now })
        pipeline.onPendingTimeout = { fellBack.set() }
        let all = try datagrams(24)
        pipeline.ingest(all[0])
        clock.now = NvstAudioReceivePipeline.pendingTimeoutNanoseconds - 1
        pipeline.ingest(all[1])
        #expect(pipeline.state == .pending)
        #expect(!fellBack.isSet)
        clock.now = NvstAudioReceivePipeline.pendingTimeoutNanoseconds
        for datagram in all.dropFirst(2) { pipeline.ingest(datagram) }
        #expect(fellBack.isSet)
        #expect(pipeline.state == .decoding(.stereo))
        #expect(!pipeline.pull().isEmpty)
    }

    @Test func aChangedLayoutReplacesTheDecoder() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp())
        try pipeline.configure(layout: .surround51)
        #expect(pipeline.state == .decoding(.surround51))
        #expect(pipeline.layout == .surround51)
    }

    /// A reader still set up for the old channel count must not take samples of the new one, or
    /// every later frame would be read from the wrong channel.
    @Test func aPullForAnotherChannelCountTakesNothing() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp())
        for datagram in try datagrams(16) { pipeline.ingest(datagram) }
        #expect(pipeline.pull(frames: 240, channels: 6).isEmpty)
        #expect(pipeline.pull(frames: 240, channels: 2).count == 480)
    }
}
