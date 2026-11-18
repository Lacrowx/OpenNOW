import XCTest
@testable import OpenNOWiOS

final class TVConsoleGameFactsTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    func testLastPlayedNamesRecentDays() {
        XCTAssertNil(TVConsoleGameFacts.lastPlayed(nil, now: now, calendar: calendar))
        XCTAssertEqual(TVConsoleGameFacts.lastPlayed(daysAgo(0.1), now: now, calendar: calendar), "Played today")
        XCTAssertEqual(TVConsoleGameFacts.lastPlayed(daysAgo(1), now: now, calendar: calendar), "Played yesterday")
        XCTAssertEqual(TVConsoleGameFacts.lastPlayed(daysAgo(3), now: now, calendar: calendar), "Played 3 days ago")
        XCTAssertTrue(TVConsoleGameFacts.lastPlayed(daysAgo(30), now: now, calendar: calendar)!.hasPrefix("Played "))
        XCTAssertFalse(TVConsoleGameFacts.lastPlayed(daysAgo(30), now: now, calendar: calendar)!.contains("ago"))
        // A date ahead of the clock still reads as today.
        XCTAssertEqual(TVConsoleGameFacts.lastPlayed(daysAgo(-2), now: now, calendar: calendar), "Played today")
    }

    func testPlaytimeText() {
        XCTAssertNil(TVConsoleGameFacts.playtime(59))
        XCTAssertEqual(TVConsoleGameFacts.playtime(48 * 60), "48 min")
        XCTAssertEqual(TVConsoleGameFacts.playtime(2 * 3600), "2 h")
        XCTAssertEqual(TVConsoleGameFacts.playtime(12 * 3600 + 40 * 60 + 30), "12 h 40 m")
    }

    func testTierRequirement() {
        XCTAssertNil(TVConsoleGameFacts.tierRequirement(nil))
        XCTAssertNil(TVConsoleGameFacts.tierRequirement("  "))
        XCTAssertEqual(TVConsoleGameFacts.tierRequirement("ULTIMATE")?.lowercased(), "needs ultimate")
    }

    private func subscription(remaining: Double, total: Double = 100, unlimited: Bool = false) -> SubscriptionSnapshot {
        SubscriptionSnapshot(membershipTier: "PERFORMANCE", subscriptionType: nil, subscriptionSubType: nil,
                             isGamePlayAllowed: true, isUnlimited: unlimited, remainingHours: remaining,
                             totalHours: total, storageAddon: nil)
    }

    func testPlaytimeLeftHiddenCases() {
        XCTAssertNil(TVConsoleGameFacts.playtimeLeft(nil))
        XCTAssertNil(TVConsoleGameFacts.playtimeLeft(subscription(remaining: 5, unlimited: true)))
        XCTAssertNil(TVConsoleGameFacts.playtimeLeft(subscription(remaining: 5, total: 0)))
    }

    func testPlaytimeLeftText() {
        XCTAssertEqual(TVConsoleGameFacts.playtimeLeft(subscription(remaining: 40))?.text, "40 h left")
        XCTAssertEqual(TVConsoleGameFacts.playtimeLeft(subscription(remaining: 40))?.isLow, false)
        XCTAssertEqual(TVConsoleGameFacts.playtimeLeft(subscription(remaining: 0.58))?.text, "35 min left")
        XCTAssertEqual(TVConsoleGameFacts.playtimeLeft(subscription(remaining: 2))?.isLow, true)
        XCTAssertEqual(TVConsoleGameFacts.playtimeLeft(subscription(remaining: -1))?.text, "0 min left")
        XCTAssertTrue(TVConsoleGameFacts.playtimeLeft(subscription(remaining: 12.5))!.text.hasSuffix(" h left"))
        XCTAssertTrue(TVConsoleGameFacts.playtimeLeft(subscription(remaining: 12.5))!.text.hasPrefix("12"))
    }

    func testPlayedDurationMatchesTitleIgnoringCase() {
        func record(_ title: String, minutes: Double) -> StreamSessionRecord {
            var record = StreamSessionRecord(gameTitle: title, resolution: "1920x1080", targetFPS: 60, codec: "H.265",
                                             hdr: false, transport: "UDP", at: now)
            record.endedAt = now.addingTimeInterval(minutes * 60)
            return record
        }
        let records = [record("Night Drive", minutes: 30), record(" night drive ", minutes: 15), record("Other", minutes: 99)]
        XCTAssertEqual(StreamSessionRecord.playedDuration(of: "Night Drive", in: records), 45 * 60)
        XCTAssertEqual(StreamSessionRecord.playedDuration(of: "Missing", in: records), 0)
        XCTAssertEqual(StreamSessionRecord.playedDuration(of: "", in: records), 0)
    }

    func testMakersListTheDeveloperOnlyWhenDifferent() {
        func game(publisher: String?, developer: String?) -> CloudGame {
            CloudGame(id: "g", title: "G", genre: "Action", platform: "STEAM", icon: "", imageUrl: nil,
                      launchAppId: nil, launchOptions: [], uuid: nil, summary: nil, longDescription: nil,
                      publisher: publisher, developer: developer, releaseDate: nil, featureLabels: nil, tags: nil,
                      stores: nil, playType: nil, membershipTierLabel: nil, catalogSectionId: nil,
                      catalogSectionTitle: nil, contentRatings: nil)
        }
        XCTAssertEqual(game(publisher: "Pub", developer: "Dev").consoleMakers, ["Pub", "Dev"])
        XCTAssertEqual(game(publisher: "Pub", developer: "pub").consoleMakers, ["Pub"])
        XCTAssertEqual(game(publisher: nil, developer: "Dev").consoleMakers, ["Dev"])
        XCTAssertEqual(game(publisher: " ", developer: nil).consoleMakers, [])
    }
}
