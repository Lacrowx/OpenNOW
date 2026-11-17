import Foundation
import Testing
@testable import OpenNOWiOS

struct NvstAudioChannelMeterTests {
    /// One second, two channels: an 80 Hz tone and a 1 kHz tone, both at half scale.
    private func twoTones() -> [Float] {
        (0..<48_000).flatMap { frame -> [Float] in
            let time = Double(frame) / 48_000
            return [Float(sin(2 * Double.pi * 80 * time)) * 0.5, Float(sin(2 * Double.pi * 1_000 * time)) * 0.5]
        }
    }

    @Test func aLowToneReadsFarLowerAbove200HzThanAHighTone() {
        var meter = NvstAudioChannelMeter()
        meter.add(twoTones(), channels: 2)
        let readings = meter.take()
        #expect(readings.count == 2)
        // Half scale is -9 dBFS RMS on both channels.
        #expect(abs(readings[0].level - -9) < 0.5)
        #expect(abs(readings[1].level - -9) < 0.5)
        #expect(readings[0].levelAbove200Hz < readings[0].level - 6)
        #expect(readings[1].levelAbove200Hz > readings[1].level - 1)
    }

    @Test func takingResetsTheWindow() {
        var meter = NvstAudioChannelMeter()
        meter.add(twoTones(), channels: 2)
        _ = meter.take()
        #expect(meter.take().isEmpty)
    }

    @Test func silenceIsFlooredAndTheSummaryIsOnePairPerChannel() {
        var meter = NvstAudioChannelMeter()
        meter.add([Float](repeating: 0, count: 960), channels: 2)
        let readings = meter.take()
        #expect(readings.allSatisfy { $0.level <= -119 && $0.levelAbove200Hz <= -119 })
        #expect(NvstAudioChannelMeter.summary(readings) == "-120/-120 -120/-120")
    }
}
