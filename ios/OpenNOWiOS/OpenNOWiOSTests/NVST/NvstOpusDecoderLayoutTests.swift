import Foundation
import Testing
@testable import OpenNOWiOS

struct NvstOpusDecoderLayoutTests {
    @Test func aDecoderBuildsForEveryOfficialLayout() throws {
        for layout in [NvstAudioLayout.stereo, .surround51, .surround71] {
            let decoder = try NvstOpusDecoder(layout: layout)
            #expect(decoder.layout == layout)
        }
    }

    /// The default decoder is the stereo one the receive path has always used.
    @Test func stereoStillDecodesWholeFrames() throws {
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: 240)
        var tone = [Float](repeating: 0, count: 240 * 2)
        for frame in 0..<240 {
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000)) * 0.5
            tone[frame * 2] = value
            tone[frame * 2 + 1] = value
        }
        let decoder = try NvstOpusDecoder()
        var decoded = 0
        for _ in 0..<20 {
            guard let packet = try encoder.encode(tone) else { continue }
            decoded += try decoder.decode(packet)?.count ?? 0
        }
        #expect(decoded > 0)
        #expect(decoded % 2 == 0)
        #expect(decoder.failedPackets == 0)
    }
}
