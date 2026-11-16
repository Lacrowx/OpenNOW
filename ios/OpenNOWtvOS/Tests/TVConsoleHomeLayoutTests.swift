import XCTest
@testable import OpenNOWiOS

final class TVConsoleHomeLayoutTests: XCTestCase {
    private func ids(_ count: Int) -> [String] { (0..<count).map { "g\($0)" } }

    private func places(_ layout: TVConsoleHomeLayout) -> [String] {
        layout.items.map { "\($0.gameID ?? "+")@\($0.row),\($0.column)\($0.wide ? "w" : "")" }
    }

    // MARK: Content

    func testPinnedGamesWinOverRecentOnes() {
        XCTAssertEqual(TVConsoleHomeContent.gameIDs(pinned: ["a", "b"], recent: ["x", "y"]), ["a", "b"])
    }

    func testRecentGamesFillHomeWhileNothingIsPinned() {
        let recent = ids(20)
        XCTAssertEqual(TVConsoleHomeContent.gameIDs(pinned: [], recent: recent), Array(recent.prefix(15)))
    }

    func testARunningGameLeadsHomeUnlessItIsAlreadyThere() {
        XCTAssertEqual(TVConsoleHomeContent.gameIDs(pinned: ["a", "b"], recent: [], running: "r"), ["r", "a", "b"])
        XCTAssertEqual(TVConsoleHomeContent.gameIDs(pinned: ["a", "b"], recent: [], running: "b"), ["a", "b"])
        XCTAssertEqual(TVConsoleHomeContent.gameIDs(pinned: [], recent: ["x"], running: "r"), ["r", "x"])
    }

    func testFirstTileIsWideUntilASizeWasChosen() {
        XCTAssertEqual(TVConsoleHomeContent.wideIDs(explicit: nil, gameIDs: ["a", "b"]), ["a"])
        XCTAssertEqual(TVConsoleHomeContent.wideIDs(explicit: [], gameIDs: ["a", "b"]), [])
        XCTAssertEqual(TVConsoleHomeContent.wideIDs(explicit: ["b"], gameIDs: ["a", "b"]), ["b"])
    }

    func testMovingATileTakesTheTargetsPlace() {
        XCTAssertEqual(TVConsoleHomeContent.moving("a", onto: "c", in: ["a", "b", "c", "d"]), ["b", "c", "a", "d"])
        XCTAssertEqual(TVConsoleHomeContent.moving("d", onto: "b", in: ["a", "b", "c", "d"]), ["a", "d", "b", "c"])
        XCTAssertEqual(TVConsoleHomeContent.moving("a", onto: "zz", in: ["a", "b"]), ["a", "b"])
    }

    // MARK: Packing

    func testNoGamesLeavesOnlyTheAddTile() {
        XCTAssertEqual(places(TVConsoleHomeLayout(gameIDs: [], wideIDs: [])), ["+@0,0"])
    }

    func testAddTileFollowsTheLastGame() {
        XCTAssertEqual(places(TVConsoleHomeLayout(gameIDs: ["a", "b"], wideIDs: ["a"])),
                       ["a@0,0w", "b@0,2", "+@0,3"])
    }

    func testAFullRowPushesTheAddTileToTheNextRow() {
        let layout = TVConsoleHomeLayout(gameIDs: ids(8), wideIDs: [])
        XCTAssertEqual(layout.items.last, .init(gameID: nil, wide: false, row: 1, column: 0))
    }

    func testAWideTileThatDoesNotFitWrapsToTheNextRow() {
        let layout = TVConsoleHomeLayout(gameIDs: ids(8), wideIDs: ["g7"])
        XCTAssertEqual(places(layout).suffix(2), ["g7@1,0w", "+@1,2"])
    }

    func testGamesBeyondThreeRowsAreDroppedAndAFullGridHasNoAddTile() {
        let layout = TVConsoleHomeLayout(gameIDs: ids(30), wideIDs: [])
        XCTAssertEqual(layout.items.count, 24)
        XCTAssertNil(layout.items.first { $0.gameID == nil })
        XCTAssertEqual(layout.items.last?.gameID, "g23")
    }

    // MARK: Neighbours (move mode)

    func testHorizontalNeighbourStaysInTheRow() {
        let layout = TVConsoleHomeLayout(gameIDs: ids(10), wideIDs: [])
        XCTAssertEqual(layout.neighbor(of: "g1", toward: .right)?.gameID, "g2")
        XCTAssertEqual(layout.neighbor(of: "g1", toward: .left)?.gameID, "g0")
        XCTAssertNil(layout.neighbor(of: "g7", toward: .right))
        XCTAssertNil(layout.neighbor(of: "g0", toward: .left))
    }

    func testVerticalNeighbourIsTheNearestColumnInTheNearestRow() {
        let layout = TVConsoleHomeLayout(gameIDs: ids(10), wideIDs: [])
        XCTAssertEqual(layout.neighbor(of: "g1", toward: .down)?.gameID, "g9")
        XCTAssertEqual(layout.neighbor(of: "g9", toward: .up)?.gameID, "g1")
        // Row 1 holds g8, g9 and the add tile at column 2; column 6 is nearest to that one.
        XCTAssertNil(layout.neighbor(of: "g6", toward: .down)?.gameID)
        XCTAssertNil(layout.neighbor(of: "g1", toward: .up))
    }
}
