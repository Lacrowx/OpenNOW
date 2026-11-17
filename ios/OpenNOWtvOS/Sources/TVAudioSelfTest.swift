#if DEBUG
import Foundation

/// `--opennow-audio-selftest`: decodes the bundled surround clips with the app's Opus decoder and
/// prints which tone came out on which channel. It answers on the Apple TV itself what the unit
/// test answers in the simulator: that this device's decoder handles Opus multistream.
enum TVAudioSelfTest {
    struct Case {
        let name: String
        let clip: String
        let layout: NvstAudioLayout
        /// The tone on each decoded channel, in hertz.
        let expected: [Double]
    }

    /// Each clip once with the table its encoder wrote and once with the seat's table for the same
    /// stream shape, which reorders the decoded channels and so shows the table is honoured.
    static let cases: [Case] = [
        Case(name: "5.1, encoder table", clip: TVAudioSelfTestClips.surround51,
             layout: NvstAudioLayout(channels: 6, streams: 4, coupledStreams: 2, mapping: [0, 4, 1, 2, 3, 5])!,
             expected: [300, 700, 500, 1100, 1300, 80]),
        Case(name: "5.1, seat table", clip: TVAudioSelfTestClips.surround51, layout: .surround51,
             expected: [300, 700, 500, 80, 1100, 1300]),
        Case(name: "7.1, encoder table", clip: TVAudioSelfTestClips.surround71,
             layout: NvstAudioLayout(channels: 8, streams: 5, coupledStreams: 3,
                                     mapping: [0, 6, 1, 2, 3, 4, 5, 7])!,
             expected: [300, 700, 500, 1700, 1900, 1100, 1300, 80]),
        Case(name: "7.1, seat table", clip: TVAudioSelfTestClips.surround71, layout: .surround71,
             expected: [300, 700, 500, 80, 1700, 1900, 1100, 1300]),
    ]

    static let candidateTones: [Double] = [80, 300, 500, 700, 1100, 1300, 1700, 1900]

    /// The strongest tone on each decoded channel, or nil when the clip did not decode cleanly.
    static func decodedTones(_ testCase: Case) -> [Double]? {
        guard let data = Data(base64Encoded: testCase.clip),
              let decoder = try? NvstOpusDecoder(layout: testCase.layout) else { return nil }
        var samples: [Float] = []
        var offset = 0
        while offset + 2 <= data.count {
            let length = Int(data[offset]) | Int(data[offset + 1]) << 8
            guard offset + 2 + length <= data.count else { return nil }
            // A nil result is normal for the first packets, while the decoder fills.
            if let decoded = try? decoder.decode(data.subdata(in: (offset + 2)..<(offset + 2 + length))) {
                samples += decoded
            }
            offset += 2 + length
        }
        let channels = testCase.layout.channels
        let frames = samples.count / channels
        let skipped = 1_920 // 40 ms: the decoder's start-up
        guard decoder.failedPackets == 0, frames >= skipped + 4_800 else { return nil }
        return (0..<channels).map { channel in
            strongestTone(in: (skipped..<frames).map { samples[$0 * channels + channel] })
        }
    }

    /// Goertzel power at each candidate frequency; the strongest names the channel's tone.
    static func strongestTone(in signal: [Float]) -> Double {
        var strongest = (tone: 0.0, power: -1.0)
        for tone in candidateTones {
            let coefficient = 2 * cos(2 * Double.pi * tone / 48_000)
            var previous = 0.0
            var beforePrevious = 0.0
            for sample in signal {
                let value = Double(sample) + coefficient * previous - beforePrevious
                beforePrevious = previous
                previous = value
            }
            let power = previous * previous + beforePrevious * beforePrevious
                - coefficient * previous * beforePrevious
            if power > strongest.power { strongest = (tone, power) }
        }
        return strongest.tone
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--opennow-audio-selftest") else { return }
        for testCase in cases {
            let tones = decodedTones(testCase)
            let decoded = tones.map { $0.map { String(Int($0)) }.joined(separator: ",") } ?? "nothing"
            print("[TVStream] audio selftest \(testCase.name): \(tones == testCase.expected ? "PASS" : "FAIL") decoded=\(decoded)")
        }
    }
}
#endif
