import XCTest
@testable import OpenNOWiOS

final class TVTriggerFeelTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "TVTriggerFeelTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAGameWithoutAChoiceHasFreeTriggers() {
        XCTAssertEqual(TVTriggerFeelStore(defaults: defaults).feels(forGame: "control"), TVTriggerFeels(left: .off, right: .off))
    }

    func testFeelsAreKeptPerGame() {
        let store = TVTriggerFeelStore(defaults: defaults)
        store.set(TVTriggerFeels(left: .softResistance, right: .weapon), forGame: "control")
        store.set(TVTriggerFeels(left: .off, right: .firmResistance), forGame: "witcher")
        // A second store reads what the first wrote, as the next session does.
        let reopened = TVTriggerFeelStore(defaults: defaults)
        XCTAssertEqual(reopened.feels(forGame: "control"), TVTriggerFeels(left: .softResistance, right: .weapon))
        XCTAssertEqual(reopened.feels(forGame: "witcher"), TVTriggerFeels(left: .off, right: .firmResistance))
        XCTAssertEqual(reopened.feels(forGame: "other"), TVTriggerFeels())
    }

    func testChoosingOffForBothTriggersForgetsTheGame() {
        let store = TVTriggerFeelStore(defaults: defaults)
        store.set(TVTriggerFeels(left: .weapon, right: .weapon), forGame: "control")
        store.set(TVTriggerFeels(), forGame: "control")
        XCTAssertEqual(store.feels(forGame: "control"), TVTriggerFeels())
        XCTAssertNil(defaults.object(forKey: TVTriggerFeelStore.key))
    }

    func testUnreadableStoredFeelsCountAsNoChoice() {
        defaults.set(Data("not json".utf8), forKey: TVTriggerFeelStore.key)
        XCTAssertEqual(TVTriggerFeelStore(defaults: defaults).feels(forGame: "control"), TVTriggerFeels())
    }

    func testSteppingCyclesThroughEveryFeelBothWays() {
        XCTAssertEqual(TVTriggerFeel.off.stepped(by: 1), .softResistance)
        XCTAssertEqual(TVTriggerFeel.weapon.stepped(by: 1), .off)
        XCTAssertEqual(TVTriggerFeel.off.stepped(by: -1), .weapon)
        var feel = TVTriggerFeel.off
        for _ in TVTriggerFeel.allCases { feel = feel.stepped(by: 1) }
        XCTAssertEqual(feel, .off)
    }

    func testEachFeelPlaysItsEffect() {
        XCTAssertEqual(TVTriggerFeel.off.effect, .off)
        XCTAssertEqual(TVTriggerFeel.softResistance.effect, .feedback(strengths: [0, 0, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375, 0.375]))
        XCTAssertEqual(TVTriggerFeel.firmResistance.effect, .feedback(strengths: [0, 0, 0.75, 0.75, 0.75, 0.75, 0.75, 0.75, 0.75, 0.75]))
        XCTAssertEqual(TVTriggerFeel.weapon.effect, .weapon(start: 2.0 / 9, end: 5.0 / 9, strength: 1))
        XCTAssertEqual(Set(TVTriggerFeel.allCases.map(\.title)).count, TVTriggerFeel.allCases.count)
    }
}
