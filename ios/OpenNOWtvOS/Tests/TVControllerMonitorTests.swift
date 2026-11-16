import XCTest
@testable import OpenNOWiOS

final class TVControllerMonitorTests: XCTestCase {
    func testHiddenWhenAControllerIsConnected() {
        XCTAssertFalse(TVControllerMonitor.shouldShow(hasGamepad: true, videoActive: false, secondsSinceVideo: 0))
        XCTAssertFalse(TVControllerMonitor.shouldShow(hasGamepad: true, videoActive: true, secondsSinceVideo: 1))
    }

    func testShownWhileConnectingWithoutAController() {
        XCTAssertTrue(TVControllerMonitor.shouldShow(hasGamepad: false, videoActive: false, secondsSinceVideo: 0))
        XCTAssertTrue(TVControllerMonitor.shouldShow(hasGamepad: false, videoActive: false, secondsSinceVideo: 999))
    }

    func testShownBrieflyOnceVideoRuns() {
        XCTAssertTrue(TVControllerMonitor.shouldShow(hasGamepad: false, videoActive: true, secondsSinceVideo: 0))
        XCTAssertFalse(TVControllerMonitor.shouldShow(hasGamepad: false, videoActive: true,
            secondsSinceVideo: TVControllerMonitor.streamingSeconds))
        XCTAssertFalse(TVControllerMonitor.shouldShow(hasGamepad: false, videoActive: true, secondsSinceVideo: .infinity))
    }
}
