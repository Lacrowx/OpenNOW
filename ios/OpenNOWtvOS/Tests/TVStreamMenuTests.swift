import XCTest
@testable import OpenNOWiOS

/// The in-stream menu's rows and navigation, without a stream behind it.
final class TVStreamMenuTests: XCTestCase {
    private let playing = TVStreamMenu.Context()
    private let failed = TVStreamMenu.Context(failed: true)

    private func openMenu() -> TVStreamMenu {
        var menu = TVStreamMenu()
        menu.setVisible(true)
        return menu
    }

    func testAClosedMenuOverAPlayingStreamHasNoRowsAndIgnoresCommands() {
        var menu = TVStreamMenu()
        XCTAssertEqual(menu.items(in: playing), [])
        XCTAssertNil(menu.handle(.activate, in: playing))
        XCTAssertEqual(menu, TVStreamMenu())
    }

    func testTheOpenMenuOffersTriggerFeelsOnlyWithADualSense() {
        let menu = openMenu()
        XCTAssertEqual(menu.items(in: playing), [.resume, .showStats, .leave, .endSession])
        XCTAssertEqual(menu.items(in: .init(statsVisible: true, dualSense: true)),
                       [.resume, .hideStats, .leftTriggerFeel, .rightTriggerFeel, .leave, .endSession])
    }

    func testAFailedStreamHasItsOwnRowsWithoutTheMenuOpen() {
        let menu = TVStreamMenu()
        XCTAssertEqual(menu.items(in: failed), [.close, .endSession])
        XCTAssertEqual(menu.items(in: .init(failed: true, canRetry: true)), [.retry, .close, .endSession])
    }

    func testBackResumesTheGameOrLeavesAFailedStream() {
        var menu = openMenu()
        XCTAssertEqual(menu.handle(.back, in: playing), .resume)
        var failedMenu = TVStreamMenu()
        XCTAssertEqual(failedMenu.handle(.back, in: failed), .leave)
    }

    func testSelectionStopsAtBothEnds() {
        var menu = openMenu()
        XCTAssertNil(menu.handle(.up, in: playing))
        XCTAssertEqual(menu.selection, 0)
        for _ in 0..<10 { _ = menu.handle(.down, in: playing) }
        XCTAssertEqual(menu.selection, 3)
    }

    func testEndingTheSessionAsksFirstAndBackReturnsToTheRow() {
        var menu = openMenu()
        for _ in 0..<3 { _ = menu.handle(.down, in: playing) }
        XCTAssertNil(menu.handle(.activate, in: playing))
        XCTAssertTrue(menu.confirmingEnd)
        XCTAssertEqual(menu.items(in: playing), [.keepPlaying, .confirmEndSession])
        XCTAssertEqual(menu.selection, 0, "Keep Playing is lit first")

        XCTAssertNil(menu.handle(.back, in: playing))
        XCTAssertFalse(menu.confirmingEnd)
        XCTAssertEqual(menu.selection, 3, "End Session is lit again")

        _ = menu.handle(.activate, in: playing)
        _ = menu.handle(.down, in: playing)
        XCTAssertEqual(menu.handle(.activate, in: playing), .endSession)
    }

    func testRowsAskForTheirActions() {
        var menu = openMenu()
        XCTAssertEqual(menu.handle(.activate, in: playing), .resume)
        _ = menu.handle(.down, in: playing)
        XCTAssertEqual(menu.handle(.activate, in: playing), .setStatsVisible(true))
        let statsShown = TVStreamMenu.Context(statsVisible: true)
        XCTAssertEqual(menu.handle(.activate, in: statsShown), .setStatsVisible(false))
        _ = menu.handle(.down, in: playing)
        XCTAssertEqual(menu.handle(.activate, in: playing), .leave)

        var failedMenu = TVStreamMenu()
        XCTAssertEqual(failedMenu.handle(.activate, in: .init(failed: true, canRetry: true)), .retry)
    }

    func testLeftAndRightStepOnlyATriggerFeelRow() {
        let dualSense = TVStreamMenu.Context(dualSense: true)
        var menu = openMenu()
        XCTAssertNil(menu.handle(.right, in: dualSense), "Resume is lit")
        _ = menu.handle(.down, in: dualSense)
        _ = menu.handle(.down, in: dualSense)
        XCTAssertEqual(menu.handle(.left, in: dualSense), .stepTriggerFeel(.leftTriggerFeel, by: -1))
        XCTAssertEqual(menu.handle(.right, in: dualSense), .stepTriggerFeel(.leftTriggerFeel, by: 1))
        XCTAssertEqual(menu.handle(.activate, in: dualSense), .stepTriggerFeel(.leftTriggerFeel, by: 1))
    }

    func testOpeningAgainStartsAtTheFirstRowOutsideTheQuestion() {
        var menu = openMenu()
        for _ in 0..<3 { _ = menu.handle(.down, in: playing) }
        _ = menu.handle(.activate, in: playing)
        menu.setVisible(false)
        menu.setVisible(true)
        XCTAssertEqual(menu.selection, 0)
        XCTAssertFalse(menu.confirmingEnd)
    }
}
