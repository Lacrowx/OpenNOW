import XCTest
@testable import OpenNOWiOS

/// The settings test page plays the bytes a game would write, so each preset has to decode to
/// the effect its row promises.
final class TVTriggerEffectTestTests: XCTestCase {
    private typealias Effect = NvstHidPassthrough.DualSense.TriggerEffect

    func testResistanceIsFullFeedbackFromTheFourthZone() {
        XCTAssertEqual(TVTriggerEffectTest.resistance.effect, Effect.feedback(strengths: [0, 0, 0, 1, 1, 1, 1, 1, 1, 1]))
    }

    func testWeaponHoldsBetweenTheThirdAndSixthZone() {
        XCTAssertEqual(TVTriggerEffectTest.weapon.effect, Effect.weapon(start: 2.0 / 9, end: 5.0 / 9, strength: 1))
    }

    func testVibrationsDifferOnlyInFrequency() {
        let amplitudes: [Float] = [0, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        XCTAssertEqual(TVTriggerEffectTest.slowVibration.effect, Effect.vibration(amplitudes: amplitudes, frequency: 10.0 / 255))
        XCTAssertEqual(TVTriggerEffectTest.fastVibration.effect, Effect.vibration(amplitudes: amplitudes, frequency: 40.0 / 255))
    }

    func testEveryPresetIsAnElevenByteEffectWithATitle() {
        for preset in TVTriggerEffectTest.allCases {
            XCTAssertEqual(preset.bytes.count, 11, preset.rawValue)
            XCTAssertFalse(preset.title.isEmpty, preset.rawValue)
            XCTAssertNotEqual(preset.effect, .off, preset.rawValue)
        }
    }
}
