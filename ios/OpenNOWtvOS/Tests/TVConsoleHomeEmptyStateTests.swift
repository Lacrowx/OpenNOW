import XCTest
@testable import OpenNOWiOS

final class TVConsoleHomeEmptyStateTests: XCTestCase {
    func testLoadingWinsOverAnOldError() {
        XCTAssertEqual(TVConsoleHomeEmptyState(isLoading: true, catalogError: "offline"), .loading)
    }

    func testAFailedCatalogCarriesItsError() {
        XCTAssertEqual(TVConsoleHomeEmptyState(isLoading: false, catalogError: "offline"), .failed("offline"))
    }

    func testOnlyALoadedCatalogIsReady() {
        let state = TVConsoleHomeEmptyState(isLoading: false, catalogError: nil)
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(state.title, "Your Home is ready")
    }
}
