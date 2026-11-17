import XCTest
@testable import OpenNOWiOS

final class TVStreamConditionsTests: XCTestCase {
    // MARK: Audio route

    func testSlowBluetoothSoundIsPointedOut() {
        let route = TVAudioRoute(name: "AirPods Pro", kind: .bluetooth, latencyMs: 182)
        XCTAssertEqual(route.notice, "AirPods Pro plays the sound about 182 ms late. Sound through the TV is in step with the picture.")
        XCTAssertEqual(route.figure, "AirPods Pro · 182 ms")
    }

    func testHDMISoundIsNeverPointedOut() {
        let route = TVAudioRoute(name: "LG TV", kind: .hdmi, latencyMs: 90)
        XCTAssertNil(route.notice)
        XCTAssertEqual(route.figure, "HDMI · 90 ms")
    }

    func testFastWirelessSoundIsNotPointedOut() {
        XCTAssertNil(TVAudioRoute(name: "Headphones", kind: .bluetooth, latencyMs: 40).notice)
    }

    // MARK: Wi-Fi trouble

    func testSustainedLossOnWiFiIsReportedOnce() {
        var detector = TVWiFiTroubleDetector()
        let results = (0..<8).map { _ in detector.shouldReport(network: .wifi, lossPercent: 3, jitterMs: 2) }
        XCTAssertEqual(results, [false, false, false, false, true, false, false, false])
    }

    func testAGoodReadingRestartsTheCount() {
        var detector = TVWiFiTroubleDetector()
        for _ in 0..<4 { _ = detector.shouldReport(network: .wifi, lossPercent: 0, jitterMs: 30) }
        XCTAssertFalse(detector.shouldReport(network: .wifi, lossPercent: 0, jitterMs: 3))
        for _ in 0..<4 { XCTAssertFalse(detector.shouldReport(network: .wifi, lossPercent: 0, jitterMs: 30)) }
        XCTAssertTrue(detector.shouldReport(network: .wifi, lossPercent: 0, jitterMs: 30))
    }

    func testTroubleOnEthernetIsNotBlamedOnWiFi() {
        var detector = TVWiFiTroubleDetector()
        for _ in 0..<10 { XCTAssertFalse(detector.shouldReport(network: .wired, lossPercent: 9, jitterMs: 40)) }
    }

    // MARK: Controller battery

    func testBatteryWarningsAreAtFifteenAndFivePercentWhileDischarging() {
        XCTAssertNil(TVControllerBattery(player: 1, percent: 40, charging: false).warningLevel)
        XCTAssertEqual(TVControllerBattery(player: 1, percent: 15, charging: false).warningLevel, 15)
        XCTAssertEqual(TVControllerBattery(player: 1, percent: 4, charging: false).warningLevel, 5)
        XCTAssertNil(TVControllerBattery(player: 1, percent: 4, charging: true).warningLevel)
        XCTAssertNil(TVControllerBattery(player: 1, percent: nil, charging: false).warningLevel)
    }

    func testBatteryLabelsNameThePlayer() {
        XCTAssertEqual(TVControllerBattery(player: 2, percent: 62, charging: false).label, "P2 62%")
        XCTAssertEqual(TVControllerBattery(player: 1, percent: 80, charging: true).label, "P1 charging")
        XCTAssertEqual(TVControllerBattery(player: nil, percent: nil, charging: false).label, "Pad")
    }

    // MARK: Session report

    func testAWiFiSessionWithLossIsAdvisedToUseEthernet() {
        let findings = StreamSessionReportAccumulator.buildRecommendations(
            averagePingMs: 20, packetLossPercent: 2, averageJitterMs: 4, averageFps: 60, averageDecodeMs: 4,
            targetFps: 60, targetBitrateKbps: 0, averageBitrateKbps: nil, networkKind: .wifi)
        XCTAssertTrue(findings.contains { $0.title == "Connect the Apple TV with Ethernet" })
    }

    func testAWiredSessionIsNotAdvisedToUseEthernet() {
        let findings = StreamSessionReportAccumulator.buildRecommendations(
            averagePingMs: 20, packetLossPercent: 2, averageJitterMs: 4, averageFps: 60, averageDecodeMs: 4,
            targetFps: 60, targetBitrateKbps: 0, averageBitrateKbps: nil, networkKind: .wired)
        XCTAssertFalse(findings.contains { $0.title == "Connect the Apple TV with Ethernet" })
    }
}

final class SonyPadMotionReportTests: XCTestCase {
    private typealias Pad = NvstHidPassthrough.SynthesizedDualShock4

    func testMotionIsConvertedToTheSonyRawUnits() {
        let motion = Pad.Motion(degreesPerSecond: (540, -90, 0), g: (0, 1, -0.5))
        XCTAssertEqual(motion.gyroX, 8856)
        XCTAssertEqual(motion.gyroY, -1476)
        XCTAssertEqual(motion.accelY, 8192)
        XCTAssertEqual(motion.accelZ, -4096)
    }

    func testMotionBeyondTheSensorRangeIsClamped() {
        let motion = Pad.Motion(degreesPerSecond: (5000, -5000, 0), g: (9, 0, 0))
        XCTAssertEqual(motion.gyroX, .max)
        XCTAssertEqual(motion.gyroY, .min)
        XCTAssertEqual(motion.accelX, .max)
    }

    func testTheDualShock4ReportCarriesMotionAtByteThirteen() {
        let motion = Pad.Motion(gyroX: 0x0102, gyroY: -2, gyroZ: 3, accelX: 4, accelY: 8192, accelZ: 6)
        let state = Pad.State(buttons: 0, leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0,
                              rightStickX: 0, rightStickY: 0, motion: motion)
        let data = [UInt8](Pad.report(state, gamepadIndex: 0, timestampMicroseconds: 0).data)
        XCTAssertEqual(Array(data[13...24]), [0x02, 0x01, 0xfe, 0xff, 0x03, 0x00, 0x04, 0x00, 0x00, 0x20, 0x06, 0x00])
        XCTAssertEqual(data[30], 0x1b, "the battery byte stays where it was")
    }

    func testTheDualSenseReportCarriesMotionAtByteSixteen() {
        let motion = Pad.Motion(gyroX: 1, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: -1)
        let state = Pad.State(buttons: 0, leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0,
                              rightStickX: 0, rightStickY: 0, motion: motion)
        let data = [UInt8](NvstHidPassthrough.DualSense.report(state, gamepadIndex: 0, sequence: 0, timestampMicroseconds: 0).data)
        XCTAssertEqual(Array(data[16...27]), [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff])
    }

    func testAPadWithoutMotionStillReportsZeros() {
        let state = Pad.State(buttons: 0, leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0,
                              rightStickX: 0, rightStickY: 0)
        let data = [UInt8](Pad.report(state, gamepadIndex: 0, timestampMicroseconds: 0).data)
        XCTAssertEqual(Array(data[13...24]), [UInt8](repeating: 0, count: 12))
    }
}
