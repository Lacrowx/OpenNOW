import XCTest
@testable import OpenNOWiOS

final class TVConsoleLaunchStageTests: XCTestCase {
    private func stage(status: Int?, pastQueue: Bool = false, position: Int? = nil,
                       paused: Bool = false) -> TVConsoleLaunchStage {
        TVConsoleLaunchStage(sessionStatus: status, isPastQueue: pastQueue, queuePosition: position, queuePaused: paused)
    }

    func testBeforeTheSessionExistsARigIsBeingRequested() {
        let stage = stage(status: nil, position: 12, paused: true)
        XCTAssertEqual(stage.step, .requested)
        XCTAssertNil(stage.queuePosition)
        XCTAssertEqual(stage.status, "Starting")
        XCTAssertEqual(stage.headline, "Requesting a rig")
    }

    func testAQueuedSessionShowsItsPosition() {
        let stage = stage(status: 1, position: 42)
        XCTAssertEqual(stage.step, .waitingForRig)
        XCTAssertEqual(stage.queuePosition, 42)
        XCTAssertEqual(stage.status, "In queue")
        XCTAssertEqual(stage.headline, "You’re in line")
    }

    func testAQueueWithoutAReportedPositionShowsNoNumber() {
        for position in [nil, 0, -1] as [Int?] {
            let stage = stage(status: 1, position: position)
            XCTAssertNil(stage.queuePosition)
            XCTAssertEqual(stage.headline, "Waiting for an available rig")
        }
    }

    func testAPausedQueueSaysSo() {
        let stage = stage(status: 1, position: 3, paused: true)
        XCTAssertEqual(stage.status, "Queue paused")
        XCTAssertEqual(stage.headline, "Your place is on hold")
        XCTAssertEqual(stage.queuePosition, 3)
    }

    func testPastTheQueueStatusOneIsSetupAndTheOthersAreConnecting() {
        XCTAssertEqual(stage(status: 1, pastQueue: true, position: 1).step, .settingUp)
        XCTAssertEqual(stage(status: 2, pastQueue: true).step, .connecting)
        XCTAssertEqual(stage(status: 3, pastQueue: true).step, .connecting)
        XCTAssertNil(stage(status: 1, pastQueue: true, position: 1).queuePosition)
        XCTAssertFalse(stage(status: 1, pastQueue: true, paused: true).queuePaused)
    }

    func testRailRowsReadAsDoneOnceTheirStepHasPassed() {
        let waiting = stage(status: 1, position: 5)
        XCTAssertEqual(TVConsoleLaunchStage.Step.allCases.map(waiting.label),
                       ["Session requested", "Waiting for a rig", "Setting up the rig", "Connecting the stream"])
        let connecting = stage(status: 2, pastQueue: true)
        XCTAssertEqual(TVConsoleLaunchStage.Step.allCases.map(connecting.label),
                       ["Session requested", "Got a rig", "Rig is set up", "Connecting the stream"])
    }

    // MARK: Play on chips

    func testUpToFourStoresAreAllShown() {
        XCTAssertEqual(TVConsolePlayOnChips.shown(optionCount: 4, selected: 2), [0, 1, 2, 3])
        XCTAssertEqual(TVConsolePlayOnChips.shown(optionCount: 0, selected: nil), [])
    }

    func testMoreThanFourStoresShowOnlyTheChosenOne() {
        XCTAssertEqual(TVConsolePlayOnChips.shown(optionCount: 5, selected: 3), [3])
        XCTAssertEqual(TVConsolePlayOnChips.shown(optionCount: 5, selected: nil), [])
        XCTAssertFalse(TVConsolePlayOnChips.isInline(optionCount: 5))
    }

    func testOwnershipIsOnlyClaimedWhenTheStoreReportsIt() {
        XCTAssertEqual(TVConsolePlayOnChips.ownershipLabel(isOwned: true, libraryStatus: "PLATFORM_SYNC"), "Owned")
        XCTAssertEqual(TVConsolePlayOnChips.ownershipLabel(isOwned: false, libraryStatus: "not_owned"), "Not owned")
        XCTAssertEqual(TVConsolePlayOnChips.ownershipLabel(isOwned: false, libraryStatus: nil), "Ownership unconfirmed")
    }
}
