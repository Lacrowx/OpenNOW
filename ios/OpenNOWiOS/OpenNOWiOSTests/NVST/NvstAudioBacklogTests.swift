import Foundation
import Testing
@testable import OpenNOWiOS

/// Audio that arrives late must not stay late: a pile-up is cut back to a short cushion.
struct NvstAudioBacklogTests {
    private static let key = Data(repeating: 0x11, count: 32)
    private static let salt = Data(repeating: 0x22, count: 12)

    private func srtp() throws -> NvstAudioSrtp {
        try NvstAudioSrtp(masterKey: Self.key, masterSalt: Self.salt, profile: .aeadAes256Gcm8)
    }

    /// Sealed stereo Opus datagrams (a 440 Hz tone at half scale) with consecutive sequence numbers.
    private func datagrams(_ count: Int) throws -> [Data] {
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: 240)
        let sender = try srtp()
        var packetizer = NvstAudioRtpPacketizer(ssrc: 1, payloadType: 111, initialSequenceNumber: 1, initialTimestamp: 0)
        var result: [Data] = []
        var frameOffset = 0
        while result.count < count {
            var tone = [Float](repeating: 0, count: 240 * 2)
            for frame in 0..<240 {
                let value = Float(sin(2 * Double.pi * 440 * Double(frameOffset + frame) / 48_000)) * 0.5
                tone[frame * 2] = value
                tone[frame * 2 + 1] = value
            }
            frameOffset += 240
            guard let opus = try encoder.encode(tone) else { continue }
            result.append(try sender.protect(packetizer.packet(payload: opus, framesPerPacket: 240)))
        }
        return result
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float { samples.map(abs).max() ?? 0 }

    @Test func aSteadyStreamIsNeverCut() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp())
        for datagram in try datagrams(200) {
            pipeline.ingest(datagram)
            _ = pipeline.pull(frames: 240, channels: 2)
        }
        #expect(pipeline.snapshot.backlogTrims == 0)
        #expect(pipeline.snapshot.trimmedSamples == 0)
    }

    @Test func aSmallPileUpIsLeftAlone() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp())
        for datagram in try datagrams(8) { pipeline.ingest(datagram) }
        _ = pipeline.pull(frames: 240, channels: 2)
        #expect(pipeline.snapshot.backlogTrims == 0)
    }

    /// 40 packets at once is 200 ms. After the pull, 10 ms of decoded audio and the jitter
    /// buffer's three packets (15 ms) are all that waits.
    @Test func aLargePileUpIsCutBackToTheCushion() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp())
        for datagram in try datagrams(40) { pipeline.ingest(datagram) }
        let pulled = pipeline.pull(frames: 240, channels: 2)
        #expect(pulled.count == 480)
        #expect(pipeline.snapshot.backlogTrims == 1)
        #expect(pipeline.snapshot.trimmedSamples > 0)
        #expect(abs(pipeline.backlogSeconds - 0.025) < 0.001)
    }

    /// What plays right after the cut starts quiet and reaches full level within 2.5 ms.
    @Test func theAudioAfterACutFadesIn() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp())
        for datagram in try datagrams(40) { pipeline.ingest(datagram) }
        let pulled = pipeline.pull(frames: 240, channels: 2)
        #expect(peak(pulled[0..<48]) < 0.15)       // first 0.5 ms: gain at most 0.2
        #expect(peak(pulled[240..<480]) > 0.3)     // from 2.5 ms on: full level
    }

    @Test func theBacklogIsZeroWhileNothingIsDecoded() throws {
        let pipeline = try NvstAudioReceivePipeline(srtp: try srtp(), layout: nil, now: { 0 })
        for datagram in try datagrams(8) { pipeline.ingest(datagram) }
        #expect(pipeline.backlogSeconds == 0)
    }
}
