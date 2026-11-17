import XCTest
@testable import OpenNOWiOS

/// Surround Opus through the app's decoder: every tone has to come out on its own channel.
final class TVAudioSelfTestTests: XCTestCase {
    func testEveryClipPutsEachToneOnItsChannel() {
        XCTAssertEqual(TVAudioSelfTest.cases.count, 4)
        for testCase in TVAudioSelfTest.cases {
            XCTAssertEqual(TVAudioSelfTest.decodedTones(testCase), testCase.expected, testCase.name)
        }
    }
}
