import XCTest
@testable import OpenNOWiOS

final class SessionResumeClaimTests: XCTestCase {
    private func handoff(status: Int, restored: Bool, asks: Bool) -> SessionLifecyclePolicy.ReadySessionHandoff {
        SessionLifecyclePolicy.readySessionHandoff(status: status, restoredFromEarlierRun: restored,
                                                   asksBeforeRejoining: asks)
    }

    func testASessionRestoredWhileStreamingIsClaimedBeforeTheStreamerConnects() {
        XCTAssertEqual(handoff(status: 3, restored: true, asks: false), .claimThenConnect)
    }

    func testWhereTheAppAsksFirstASessionRestoredWhileStreamingIsOfferedToTheUser() {
        XCTAssertEqual(handoff(status: 3, restored: true, asks: true), .askFirst)
    }

    func testARestoredSessionThatNeverStreamedConnectsWithoutAClaimOrAQuestion() {
        for status in [1, 2] {
            for asks in [false, true] {
                XCTAssertEqual(handoff(status: status, restored: true, asks: asks), .connect)
            }
        }
    }

    func testASessionThisRunLaunchedOrClaimedConnectsWithoutAClaimOrAQuestion() {
        for status in [1, 2, 3] {
            for asks in [false, true] {
                XCTAssertEqual(handoff(status: status, restored: false, asks: asks), .connect)
            }
        }
    }
}
