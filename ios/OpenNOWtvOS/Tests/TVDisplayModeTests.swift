import XCTest
@testable import OpenNOWiOS

/// `TVDisplayMode` reads QuartzCore's private display objects by name. A later tvOS may rename
/// or drop any of them, and that must leave the display alone, not end the app.
final class TVDisplayModeTests: XCTestCase {
    func testAPropertyThisOSDoesNotHaveReadsAsNil() {
        XCTAssertNil(TVDisplayMode.property(NSObject(), "availableModes"))
        XCTAssertNil(TVDisplayMode.property(NSObject(), "internalRepresentation"))
    }

    func testAnExistingPropertyIsRead() {
        XCTAssertEqual(TVDisplayMode.property(NSNumber(value: 120), "intValue") as? Int, 120)
    }

    /// While the TV reconnects (it does when Game Master switches) the display lists no modes for
    /// about a second. A mode chosen then is chosen from nothing, so the display is asked again.
    func testADisplayWithoutModesIsAskedAgainForAWhile() {
        XCTAssertTrue(TVDisplayMode.waitsForDisplay(modeCount: 0, attempts: 0))
        XCTAssertTrue(TVDisplayMode.waitsForDisplay(modeCount: nil, attempts: 0))
        XCTAssertTrue(TVDisplayMode.waitsForDisplay(modeCount: 0, attempts: TVDisplayMode.reconnectRetryLimit - 1))
        XCTAssertFalse(TVDisplayMode.waitsForDisplay(modeCount: 0, attempts: TVDisplayMode.reconnectRetryLimit))
        XCTAssertFalse(TVDisplayMode.waitsForDisplay(modeCount: 274, attempts: 0))
    }
}
