import Foundation
import Testing
@testable import OpenNOWiOS

/// When the shared audio session's preferred output channel count is written, and to what.
struct NvstCoreAudioFormatTests {
    private func change(requested: Int, maximum: Int, raisedEarlier: Bool, current: Int) -> Int? {
        NvstCoreAudioFormat.preferredOutputChannelChange(requested: requested, routeMaximum: maximum,
                                                         raisedEarlier: raisedEarlier, current: current)
    }

    /// A stereo stream that never raised the preference leaves it exactly as it found it.
    @Test func aStereoStreamLeavesThePreferenceAlone() {
        #expect(change(requested: 2, maximum: 8, raisedEarlier: false, current: 0) == nil)
        #expect(change(requested: 2, maximum: 8, raisedEarlier: false, current: 6) == nil)
    }

    @Test func aSurroundStreamRaisesItToWhatTheRouteCarries() {
        #expect(change(requested: 6, maximum: 8, raisedEarlier: false, current: 0) == 6)
        #expect(change(requested: 8, maximum: 8, raisedEarlier: false, current: 2) == 8)
        #expect(change(requested: 8, maximum: 6, raisedEarlier: false, current: 0) == 6)
        #expect(change(requested: 6, maximum: 2, raisedEarlier: false, current: 0) == 2)
    }

    /// Writing the preference can cause a route change, which reopens the device: never rewrite
    /// the value it already has.
    @Test func anUnchangedValueIsNotWrittenAgain() {
        #expect(change(requested: 6, maximum: 8, raisedEarlier: true, current: 6) == nil)
        #expect(change(requested: 2, maximum: 8, raisedEarlier: true, current: 2) == nil)
    }

    @Test func goingBackToStereoPutsItBack() {
        #expect(change(requested: 2, maximum: 8, raisedEarlier: true, current: 6) == 2)
    }
}
