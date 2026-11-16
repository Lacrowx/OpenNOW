import XCTest
@testable import OpenNOWiOS

final class TVStreamStatsTests: XCTestCase {
    private func sample(received: UInt64 = 0, decoded: UInt64 = 0, bytes: UInt64 = 0, lost: UInt64 = 0,
                        packets: UInt64 = 0, resolution: String? = "1920x1080", decode: Double = 5,
                        ping: Double? = 12.4) -> NativeStreamNVSTSample {
        NativeStreamNVSTSample(received: received, decoded: decoded, bytes: bytes, lost: lost, packets: packets,
            resolution: resolution, decodeMilliseconds: decode, pingMilliseconds: ping, jitterMilliseconds: 1.5,
            hardware: true, pixelFormat: "420v", bitstream: "hvc1", detail: "")
    }

    func testFirstSampleHasNoRates() {
        var stats = TVStreamStats()
        let reading = stats.read(sample(received: 60, decoded: 60, bytes: 1_000_000, packets: 500), at: 10)
        XCTAssertNil(reading.decodedFPS)
        XCTAssertNil(reading.receivedFPS)
        XCTAssertNil(reading.bitrateKbps)
        XCTAssertNil(reading.packetsLostDelta)
        XCTAssertEqual(reading.pingMs, 12)
        XCTAssertEqual(reading.decodeMs, 5)
        XCTAssertEqual(reading.resolution, "1920x1080")
    }

    func testRatesComeFromDeltasOverElapsedTime() {
        var stats = TVStreamStats()
        _ = stats.read(sample(received: 100, decoded: 90, bytes: 1_000_000, lost: 1, packets: 999), at: 10)
        let reading = stats.read(
            sample(received: 340, decoded: 330, bytes: 6_000_000, lost: 3, packets: 2_997), at: 12)
        XCTAssertEqual(reading.decodedFPS, 120)
        XCTAssertEqual(reading.receivedFPS, 120)
        XCTAssertEqual(reading.bitrateKbps, 20_000)
        XCTAssertEqual(reading.packetsLostDelta, 2)
        XCTAssertEqual(reading.packetsReceivedDelta, 1_998)
        XCTAssertEqual(reading.lossPercent, 0.1, accuracy: 0.0001)
    }

    func testCounterGoingBackwardsYieldsNoRates() {
        var stats = TVStreamStats()
        _ = stats.read(sample(received: 500, decoded: 500, bytes: 9_000_000, packets: 4_000), at: 10)
        let reading = stats.read(sample(received: 10, decoded: 10, bytes: 100_000, packets: 50), at: 11)
        XCTAssertNil(reading.decodedFPS)
        XCTAssertNil(reading.bitrateKbps)
        XCTAssertNil(reading.packetsReceivedDelta)
    }

    func testUnmeasuredDecodeTimeIsMissing() {
        var stats = TVStreamStats()
        XCTAssertNil(stats.read(sample(decode: -1), at: 1).decodeMs)
    }

    func testHudShowsEnabledMetricsThatHaveAValue() {
        var stats = TVStreamStats()
        _ = stats.read(sample(decoded: 0, bytes: 0), at: 0)
        let reading = stats.read(sample(decoded: 60, bytes: 2_500_000), at: 1)

        var metrics = StreamStatsMetrics()
        metrics.fps = true
        metrics.ping = true
        metrics.bitrate = true
        metrics.gpu = true
        // On by default, but a TV has no battery or network-type reading to show.
        metrics.battery = true
        metrics.connection = true

        XCTAssertEqual(reading.hudItems(metrics: metrics, codec: "H265", gpu: nil, server: "NP-FRK-05"),
                       ["60 fps", "12 ms", "20.0 Mbps"])

        metrics = StreamStatsMetrics()
        metrics.fps = false
        metrics.ping = false
        metrics.battery = false
        metrics.connection = false
        metrics.resolution = true
        metrics.codec = true
        metrics.location = true
        metrics.latency = true
        metrics.packetLoss = true
        XCTAssertEqual(reading.hudItems(metrics: metrics, codec: "H265", gpu: "RTX 4080", server: "NP-FRK-05"),
                       ["decode 5.0 ms", "loss 0.0%", "1920x1080", "H265", "NP-FRK-05"])
    }

    func testOnlyMetricsATVCanShowAreCounted() {
        var metrics = StreamStatsMetrics()
        metrics.fps = true
        metrics.ping = false
        metrics.battery = true
        metrics.sessionBattery = true
        metrics.connection = true
        metrics.displayedFPS = true
        metrics.renderer = true
        XCTAssertEqual(metrics.tvEnabledCount, 1)
    }
}
