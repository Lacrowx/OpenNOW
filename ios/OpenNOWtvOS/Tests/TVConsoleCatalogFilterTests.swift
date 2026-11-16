import XCTest
@testable import OpenNOWiOS

final class TVConsoleCatalogFilterTests: XCTestCase {
    private let stores = ["EPIC", "STEAM"]
    private let genres = ["Action", "Puzzle"]

    private func sections(_ filter: TVConsoleCatalogFilter, stores: [String]? = nil) -> [TVConsoleFilterSection] {
        filter.sections(sortLabels: ["Recently played", "Title"], stores: stores ?? self.stores, genres: genres,
                        showLabels: ["All library games", "Pinned to Home"], storeLabel: { $0.capitalized })
    }

    func testAnUntouchedFilterSelectsTheFirstOptionEverywhere() {
        let built = sections(TVConsoleCatalogFilter())
        XCTAssertEqual(built.map(\.kind), [.sort, .store, .genre, .show])
        XCTAssertEqual(built.map(\.selection), [0, 0, 0, 0])
        XCTAssertEqual(built[1].options, ["All stores", "Epic", "Steam"])
        XCTAssertEqual(built[2].options, ["All genres", "Action", "Puzzle"])
        XCTAssertFalse(TVConsoleCatalogFilter().isNarrowed)
    }

    func testChoosingAnOptionStoresItsValue() {
        var filter = TVConsoleCatalogFilter()
        filter.choose(2, in: .store, stores: stores, genres: genres)
        filter.choose(1, in: .genre, stores: stores, genres: genres)
        filter.choose(1, in: .sort, stores: stores, genres: genres)
        filter.choose(1, in: .show, stores: stores, genres: genres)
        XCTAssertEqual(filter, TVConsoleCatalogFilter(sort: 1, storefront: "STEAM", genre: "Action", show: 1))
        XCTAssertEqual(sections(filter).map(\.selection), [1, 2, 1, 1])
        XCTAssertTrue(filter.isNarrowed)
    }

    func testChoosingAllClearsTheValue() {
        var filter = TVConsoleCatalogFilter(storefront: "STEAM", genre: "Puzzle")
        filter.choose(0, in: .store, stores: stores, genres: genres)
        filter.choose(0, in: .genre, stores: stores, genres: genres)
        XCTAssertEqual(filter, TVConsoleCatalogFilter())
    }

    func testSortingAloneDoesNotNarrow() {
        XCTAssertFalse(TVConsoleCatalogFilter(sort: 1).isNarrowed)
    }

    func testAStoreTheCatalogNoLongerListsStaysSelectedAndClearable() {
        var filter = TVConsoleCatalogFilter(storefront: "GOG")
        let built = sections(filter)
        XCTAssertEqual(built[1].options, ["All stores", "Epic", "Steam", "Gog"])
        XCTAssertEqual(built[1].selection, 3)
        // Re-choosing it keeps it; the indices are those of the list that was shown.
        filter.choose(3, in: .store, stores: stores, genres: genres)
        XCTAssertEqual(filter.storefront, "GOG")
        filter.choose(1, in: .store, stores: stores, genres: genres)
        XCTAssertEqual(filter.storefront, "EPIC")
    }

    func testSummaryListsStoreGenreAndSortAndLeadsWithANarrowingShowChoice() {
        XCTAssertEqual(TVConsoleCatalogFilter.summary(of: sections(TVConsoleCatalogFilter())),
                       "All stores · All genres · Recently played")
        let narrowed = TVConsoleCatalogFilter(sort: 1, storefront: "STEAM", genre: nil, show: 1)
        XCTAssertEqual(TVConsoleCatalogFilter.summary(of: sections(narrowed)),
                       "Pinned to Home · Steam · All genres · Title")
    }
}
