import XCTest
@testable import OpenNOWiOS

final class TVReleaseCheckTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(TVRelease.isVersion("1.1.200", newerThan: "1.1.191"))
        XCTAssertTrue(TVRelease.isVersion("1.2", newerThan: "1.1.191"))
        XCTAssertTrue(TVRelease.isVersion("1.1.191.1", newerThan: "1.1.191"))
        XCTAssertFalse(TVRelease.isVersion("1.1.191", newerThan: "1.1.191"))
        XCTAssertFalse(TVRelease.isVersion("1.1.191.0", newerThan: "1.1.191"))
        XCTAssertFalse(TVRelease.isVersion("1.1.90", newerThan: "1.1.191"))
    }

    func testNewestSkipsDraftsPrereleasesAndOtherTags() throws {
        let json = """
        [
          {"tag_name": "v9.0.0", "name": "Desktop", "html_url": "https://github.com/x/y/releases/tag/v9.0.0", "draft": false, "prerelease": false},
          {"tag_name": "tvos-v1.3.0", "name": "Beta", "html_url": "https://github.com/x/y/releases/tag/tvos-v1.3.0", "draft": false, "prerelease": true},
          {"tag_name": "tvos-v1.4.0", "name": "Draft", "html_url": "https://github.com/x/y/releases/tag/tvos-v1.4.0", "draft": true, "prerelease": false},
          {"tag_name": "tvos-v1.1.191", "name": "OpenNOW for Apple TV 1.1.191", "html_url": "https://github.com/x/y/releases/tag/tvos-v1.1.191", "draft": false, "prerelease": false},
          {"tag_name": "tvos-v1.2.0", "name": null, "html_url": "https://github.com/x/y/releases/tag/tvos-v1.2.0", "draft": false, "prerelease": false}
        ]
        """
        let newest = try XCTUnwrap(TVRelease.newest(inListing: Data(json.utf8)))
        XCTAssertEqual(newest.version, "1.2.0")
        XCTAssertEqual(newest.name, "OpenNOW 1.2.0")
        XCTAssertEqual(newest.url.absoluteString, "https://github.com/x/y/releases/tag/tvos-v1.2.0")
    }

    func testNewestOfAnUnexpectedBodyIsNil() {
        XCTAssertNil(TVRelease.newest(inListing: Data(#"{"message": "API rate limit exceeded"}"#.utf8)))
        XCTAssertNil(TVRelease.newest(inListing: Data("[]".utf8)))
    }

    @MainActor
    func testCachedAnswerShowsOnlyANewerRelease() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TVReleaseCheckTests"))
        defaults.removePersistentDomain(forName: "TVReleaseCheckTests")
        let release = TVRelease(version: "1.2.0", name: "1.2.0", url: TVRelease.releasesPage)
        defaults.set(try JSONEncoder().encode(release), forKey: "tvReleaseCheckNewest")
        XCTAssertEqual(TVReleaseChecker(defaults: defaults, installedVersion: "1.1.191").available, release)
        XCTAssertNil(TVReleaseChecker(defaults: defaults, installedVersion: "1.2.0").available)
        defaults.set(false, forKey: "tvReleaseCheckEnabled")
        XCTAssertNil(TVReleaseChecker(defaults: defaults, installedVersion: "1.1.191").available)
        defaults.removePersistentDomain(forName: "TVReleaseCheckTests")
    }
}
