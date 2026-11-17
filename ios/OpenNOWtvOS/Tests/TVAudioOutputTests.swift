import XCTest
@testable import OpenNOWiOS

/// How many audio channels a stream asks the seat for, and how the request says so.
final class TVAudioOutputTests: XCTestCase {
    func testTheOutputAndTheLimitTogetherDecideTheCount() {
        func count(_ limit: StreamAudioChannelLimit, _ output: Int, microphone: Bool = false) -> Int {
            StreamSettingsResolver.audioChannelCount(limit: limit.rawValue, outputChannels: output,
                                                     capturesMicrophone: microphone)
        }
        XCTAssertEqual(count(.automatic, 2), 2)
        XCTAssertEqual(count(.automatic, 6), 6)
        XCTAssertEqual(count(.automatic, 7), 6)
        XCTAssertEqual(count(.automatic, 8), 8)
        XCTAssertEqual(count(.automatic, 16), 8)
        XCTAssertEqual(count(.stereo, 8), 2)
        XCTAssertEqual(count(.surround51, 8), 6)
        XCTAssertEqual(count(.surround51, 2), 2)
        XCTAssertEqual(count(.surround71, 6), 6)
        XCTAssertEqual(count(.surround71, 8), 8)
        XCTAssertEqual(count(.automatic, 8, microphone: true), 2)
    }

    func testAnUnknownSavedLimitIsAutomatic() {
        XCTAssertEqual(StreamSettingsResolver.audioChannelCount(limit: "quadraphonic", outputChannels: 8,
                                                                capturesMicrophone: false), 8)
    }

    /// Values read from the official client: format 1, 2, 3 and the channel count as text.
    func testTheRequestFields() {
        XCTAssertNil(StreamSettingsResolver.audioRequestFields(channelCount: 2).requestedAudioFormat)
        XCTAssertEqual(StreamSettingsResolver.audioRequestFields(channelCount: 2).surroundAudioInfo, "2")
        XCTAssertEqual(StreamSettingsResolver.audioRequestFields(channelCount: 6).requestedAudioFormat, 2)
        XCTAssertEqual(StreamSettingsResolver.audioRequestFields(channelCount: 6).surroundAudioInfo, "6")
        XCTAssertEqual(StreamSettingsResolver.audioRequestFields(channelCount: 8).requestedAudioFormat, 3)
        XCTAssertEqual(StreamSettingsResolver.audioRequestFields(channelCount: 8).surroundAudioInfo, "8")
    }

    func testSettingsSavedBeforeTheSoundSettingLoadAsAutomatic() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["audioChannelLimit"] as? String, "automatic")
        object.removeValue(forKey: "audioChannelLimit")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.audioChannelLimit, StreamAudioChannelLimit.automatic.rawValue)
    }

    func testAForcedCountReplacesTheOutputsAndSurroundNeedsADecoder() {
        XCTAssertEqual(TVAudioOutput.channels(carried: 2, forced: nil, canDecodeSurround: true), 2)
        XCTAssertEqual(TVAudioOutput.channels(carried: 8, forced: nil, canDecodeSurround: true), 8)
        XCTAssertEqual(TVAudioOutput.channels(carried: 2, forced: 6, canDecodeSurround: true), 6)
        XCTAssertEqual(TVAudioOutput.channels(carried: 8, forced: nil, canDecodeSurround: false), 2)
        XCTAssertEqual(TVAudioOutput.channels(carried: 2, forced: 6, canDecodeSurround: false), 2)
    }

    func testThisDeviceCanDecodeSurround() {
        XCTAssertTrue(TVAudioOutput.canDecodeSurround)
    }
}
