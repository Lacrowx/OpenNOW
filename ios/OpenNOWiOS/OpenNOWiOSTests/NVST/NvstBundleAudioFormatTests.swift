import Foundation
import Testing
@testable import OpenNOWiOS

/// What the stream menu shows as the sound format.
struct NvstBundleAudioFormatTests {
    @Test func theLabelNamesWhatIsDecodedAndWhetherItIsFolded() {
        #expect(NvstNativeBundle.audioFormatLabel(state: .decoding(.stereo), isDownmix: false) == "Stereo")
        #expect(NvstNativeBundle.audioFormatLabel(state: .decoding(.surround51), isDownmix: false) == "5.1")
        #expect(NvstNativeBundle.audioFormatLabel(state: .decoding(.surround71), isDownmix: false) == "7.1")
        #expect(NvstNativeBundle.audioFormatLabel(state: .decoding(.surround51), isDownmix: true) == "5.1 (stereo output)")
        #expect(NvstNativeBundle.audioFormatLabel(state: .unavailable, isDownmix: false) == "Unavailable")
        #expect(NvstNativeBundle.audioFormatLabel(state: .pending, isDownmix: false) == nil)
    }
}
