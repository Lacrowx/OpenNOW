import AudioToolbox
import Foundation
import Testing
@testable import OpenNOWiOS

struct NvstAudioPlacementTests {
    /// One frame of `layout`, given the value on each speaker.
    private func frame(_ layout: NvstAudioLayout, _ values: [NvstSpeaker: Float]) -> [Float] {
        layout.speakers.map { values[$0] ?? 0 }
    }

    @Test func stereoOnAStereoOutputPassesThrough() {
        let placement = NvstAudioPlacement(layout: .stereo, deviceSpeakers: [.frontLeft, .frontRight])
        #expect(!placement.isDownmix)
        #expect(placement.render([0.5, -0.5, 0.25, 1.5], frames: 2) == [16384, -16384, 8192, 32767])
    }

    @Test func stereoOnAMonoOutputIsAveraged() {
        let placement = NvstAudioPlacement(layout: .stereo, deviceSpeakers: NvstAudioPlacement.defaultSpeakers(channelCount: 1))
        #expect(!placement.isDownmix)
        #expect(placement.render([0.5, 0.25], frames: 1) == [12288])
    }

    @Test func stereoOnASurroundOutputUsesTheFrontPair() {
        let placement = NvstAudioPlacement(layout: .stereo, deviceSpeakers: NvstAudioPlacement.defaultSpeakers(channelCount: 6))
        #expect(placement.render([0.5, -0.5], frames: 1) == [16384, -16384, 0, 0, 0, 0])
    }

    @Test func aMissingFrameIsSilence() {
        let placement = NvstAudioPlacement(layout: .stereo, deviceSpeakers: [.frontLeft, .frontRight])
        #expect(placement.render([0.5, -0.5], frames: 2) == [16384, -16384, 0, 0])
    }

    /// Whatever order the device lists its speakers in, each gets the decoded channel of that speaker.
    @Test(arguments: [NvstAudioLayout.surround51, .surround71])
    func everySpeakerGetsItsOwnChannel(layout: NvstAudioLayout) throws {
        let device = NvstAudioPlacement.defaultSpeakers(channelCount: layout.channels)
        let placement = NvstAudioPlacement(layout: layout, deviceSpeakers: device)
        #expect(!placement.isDownmix)
        #expect(placement.deviceChannels == layout.channels)
        for (channel, speaker) in device.enumerated() {
            let source = try #require(speaker.flatMap { layout.speakers.firstIndex(of: $0) })
            #expect(placement.taps[channel] == [NvstAudioPlacement.Tap(source: source, gain: 1)])
        }
    }

    /// Apple's default 7.1 order lists the side pair before the rear pair.
    @Test func theDefaultSevenOneOrderHasSidesBeforeRears() {
        #expect(NvstAudioPlacement.defaultSpeakers(channelCount: 8)
                == [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight, .backLeft, .backRight])
        #expect(NvstAudioPlacement.defaultSpeakers(channelCount: 6)
                == [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight])
        #expect(NvstAudioPlacement.defaultSpeakers(channelCount: 2) == [.frontLeft, .frontRight])
    }

    /// ITU-R BS.775: centre and surrounds 3 dB down, no LFE.
    @Test func surroundOnAStereoOutputIsFoldedDown() {
        let placement = NvstAudioPlacement(layout: .surround51, deviceSpeakers: [.frontLeft, .frontRight])
        #expect(placement.isDownmix)
        let samples = frame(.surround51, [.frontLeft: 0.2, .frontRight: 0.1, .frontCenter: 0.1,
                                          .lowFrequency: 0.9, .backLeft: 0.1, .backRight: 0.2])
        let output = placement.render(samples, frames: 1)
        // Left 0.2 + 0.707 * 0.1 + 0.707 * 0.1 = 0.3414; right 0.1 + 0.707 * 0.1 + 0.707 * 0.2 = 0.3121.
        #expect(abs(Int(output[0]) - 11187) <= 1)
        #expect(abs(Int(output[1]) - 10227) <= 1)
    }

    @Test func sevenOneFoldsBothSurroundPairs() {
        let placement = NvstAudioPlacement(layout: .surround71, deviceSpeakers: [.frontLeft, .frontRight])
        let samples = frame(.surround71, [.sideLeft: 0.1, .backLeft: 0.1, .sideRight: 0.2])
        let output = placement.render(samples, frames: 1)
        #expect(abs(Int(output[0]) - 4633) <= 1)   // 0.707 * 0.1 + 0.707 * 0.1
        #expect(abs(Int(output[1]) - 4633) <= 1)   // 0.707 * 0.2
    }

    @Test func aLoudFoldDownIsClampedNotWrapped() {
        let placement = NvstAudioPlacement(layout: .surround51, deviceSpeakers: [.frontLeft, .frontRight])
        #expect(placement.render([Float](repeating: 1, count: 6), frames: 1) == [32767, 32767])
    }

    @Test func routeLabelsNameTheSpeakers() {
        let fiveOne = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                       kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        #expect(NvstAudioPlacement.speakers(forChannelLabels: fiveOne, channelCount: 6)
                == [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight])
        // With a rear pair present, the plain surround pair is the side pair.
        let sevenOne = fiveOne + [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]
        #expect(NvstAudioPlacement.speakers(forChannelLabels: sevenOne, channelCount: 8)
                == [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight, .backLeft, .backRight])
    }

    @Test func unusableLabelsFallBackToTheDefaultOrder() {
        let unknown = [UInt32](repeating: kAudioChannelLabel_Unknown, count: 6)
        #expect(NvstAudioPlacement.speakers(forChannelLabels: unknown, channelCount: 6)
                == NvstAudioPlacement.defaultSpeakers(channelCount: 6))
        #expect(NvstAudioPlacement.speakers(forChannelLabels: [kAudioChannelLabel_Left], channelCount: 2)
                == [.frontLeft, .frontRight])
    }
}
