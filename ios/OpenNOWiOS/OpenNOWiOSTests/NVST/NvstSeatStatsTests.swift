import Foundation
import Testing
@testable import OpenNOWiOS

/// The seat's qos-info message (`0x0101`): the fields this client reads out of its 80 bytes.
struct NvstSeatStatsTests {
    private func command(roundTripDelay: UInt32, gameFps: Double, length: Int = 80) -> NvstControlCommand {
        var writer = NvstByteWriter(capacity: 80)
        writer.u32LE(1)                 // +0
        writer.u32LE(3)                 // +4
        writer.u32LE(roundTripDelay)    // +8
        writer.u32LE(0)                 // +12 stream index
        writer.zeroes(12)               // +16…+27
        writer.u32LE(9)                 // +28
        writer.float64LE(gameFps)       // +32
        writer.float32LE(0.034)         // +40
        writer.zeroes(36)               // +44…+79
        return NvstControlCommand(code: .qosInfo, payload: writer.data.prefix(length))
    }

    /// Offset read from the official client's `ClientSession::handleServerQosInfoCommand`: the
    /// 32-bit value at payload +8 is what it hands to `updateMinRtd` and prints as `RTD %3ums`.
    @Test func theRoundTripDelayIsTheIntegerAtOffsetEight() throws {
        let stats = try #require(NvstSeatStats.from(command(roundTripDelay: 5, gameFps: 120.5)))
        #expect(stats.roundTripDelayMilliseconds == 5)
        #expect(stats.gameFramesPerSecond == 120.5)
        #expect(stats.counterA == 3)
        #expect(stats.counterB == 9)
    }

    @Test func aShortMessageIsNotStats() {
        #expect(NvstSeatStats.from(command(roundTripDelay: 5, gameFps: 120, length: 79)) == nil)
    }
}
