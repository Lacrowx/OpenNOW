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

    private func toOpen(requested: Int, fallback: Bool = false, failures: Int = 0) -> Int {
        NvstCoreAudioFormat.playoutChannelsToOpen(requested: requested, isStereoFallback: fallback,
                                                   surroundFailures: failures)
    }

    /// The request is what an attempt opens, until surround has failed too often since it was made.
    @Test func anAttemptOpensTheRequestUntilSurroundFailedTwice() {
        #expect(toOpen(requested: 2) == 2)
        #expect(toOpen(requested: 6) == 6)
        #expect(toOpen(requested: 8, failures: 1) == 8)
        #expect(toOpen(requested: 8, failures: 2) == 2)
        #expect(toOpen(requested: 6, failures: 3) == 2)
    }

    @Test func theStereoFallbackOpensStereo() {
        #expect(toOpen(requested: 6, fallback: true) == 2)
        #expect(toOpen(requested: 8, fallback: true, failures: 1) == 2)
    }

    /// Only an attempt that got as far as a surround format uses up an attempt and falls back,
    /// and the fallback itself never falls back again.
    @Test func whatAFailedOpenMeans() {
        let beforeFormat = NvstCoreAudioFormat.failedPlayoutOpen(openedChannels: nil, isStereoFallback: false)
        #expect(!beforeFormat.countsAsSurroundFailure && !beforeFormat.fallsBackToStereo)
        let stereo = NvstCoreAudioFormat.failedPlayoutOpen(openedChannels: 2, isStereoFallback: false)
        #expect(!stereo.countsAsSurroundFailure && !stereo.fallsBackToStereo)
        let surround = NvstCoreAudioFormat.failedPlayoutOpen(openedChannels: 6, isStereoFallback: false)
        #expect(surround.countsAsSurroundFailure && surround.fallsBackToStereo)
        let fallback = NvstCoreAudioFormat.failedPlayoutOpen(openedChannels: 2, isStereoFallback: true)
        #expect(!fallback.countsAsSurroundFailure && !fallback.fallsBackToStereo)
    }
}
