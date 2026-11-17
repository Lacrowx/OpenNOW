import XCTest
@testable import OpenNOWiOS

final class TVStreamIdleGuardTests: XCTestCase {
    func testAStreamWithRecentInputIsActive() {
        let guardian = TVStreamIdleGuard(idleMinutes: 20, now: 100)
        XCTAssertEqual(guardian.phase(at: 100 + 20 * 60 - 1), .active)
    }

    func testTheCountdownStartsAfterTheIdleTimeAndCountsDownWholeSeconds() {
        let guardian = TVStreamIdleGuard(idleMinutes: 10, now: 0)
        XCTAssertEqual(guardian.phase(at: 600), .warning(secondsLeft: 60))
        XCTAssertEqual(guardian.phase(at: 600.5), .warning(secondsLeft: 60))
        XCTAssertEqual(guardian.phase(at: 659.2), .warning(secondsLeft: 1))
    }

    func testTheCountdownRunsOutAMinuteAfterItStarts() {
        let guardian = TVStreamIdleGuard(idleMinutes: 10, now: 0)
        XCTAssertEqual(guardian.phase(at: 660), .expired)
    }

    func testInputDuringTheCountdownRestartsTheIdleTime() {
        var guardian = TVStreamIdleGuard(idleMinutes: 10, now: 0)
        guardian.noteActivity(at: 630)
        XCTAssertEqual(guardian.phase(at: 640), .active)
        XCTAssertEqual(guardian.phase(at: 1230), .warning(secondsLeft: 60))
    }

    func testAnOlderActivityTimeNeverMovesTheClockBack() {
        var guardian = TVStreamIdleGuard(idleMinutes: 10, now: 500)
        guardian.noteActivity(at: 100)
        XCTAssertEqual(guardian.lastActivity, 500)
    }

    func testAStickRestingInsideTheDeadZoneReadsAsCentred() {
        XCTAssertEqual(TVInputActivitySignature.stickStep(0.12), 0)
        XCTAssertEqual(TVInputActivitySignature.stickStep(-0.29), 0)
        XCTAssertEqual(TVInputActivitySignature.stickStep(0.9), 4)
        XCTAssertEqual(TVInputActivitySignature.stickStep(-0.5), -2)
    }

    func testUnknownIdleMinutesFallBackToTheDefault() {
        XCTAssertEqual(StreamIdleAction.normalizedMinutes(7), StreamIdleAction.defaultMinutes)
        XCTAssertEqual(StreamIdleAction.normalizedMinutes(30), 30)
    }
}
