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
}
