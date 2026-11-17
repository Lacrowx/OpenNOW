import Foundation
import Testing
@testable import OpenNOWiOS

/// The seat's audio layouts: which ones are accepted, and the decoder cookie each one gives.
struct NvstAudioLayoutTests {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func info(_ channels: UInt32, _ streams: UInt32, _ coupled: UInt32, _ mapping: [UInt8]) -> NvstAudioSurroundInfo {
        NvstAudioSurroundInfo(channels: channels, streams: streams, coupledStreams: coupled,
                              usesMultiMappingMode: false, channelMapping: mapping)
    }

    /// The official client's own parameters, from the strings in `libBifrost2.dylib`.
    @Test func theOfficialLayoutsAreAccepted() {
        #expect(NvstAudioLayout(info(6, 4, 2, [0, 4, 1, 5, 2, 3])) == .surround51)
        #expect(NvstAudioLayout(info(8, 5, 3, [0, 6, 1, 7, 2, 3, 4, 5])) == .surround71)
        #expect(NvstAudioLayout.official(channels: 6) == .surround51)
        #expect(NvstAudioLayout.official(channels: 8) == .surround71)
        #expect(NvstAudioLayout.official(channels: 2) == .stereo)
        #expect(NvstAudioLayout.official(channels: 4) == nil)
    }

    @Test func aParsedSurroundCommandGivesTheLayout() throws {
        var writer = NvstByteWriter(capacity: 22)
        writer.u32LE(6); writer.u32LE(4); writer.u32LE(2); writer.u32LE(0)
        writer.bytes([0, 4, 1, 5, 2, 3])
        let command = NvstControlCommand(code: NvstAudioSurroundInfo.commandCode, payload: writer.data)
        let parsed = try #require(NvstAudioSurroundInfo.parse(command))
        #expect(NvstAudioLayout(parsed) == .surround51)
    }

    @Test func stereoNeedsNoMappingTable() {
        #expect(NvstAudioLayout(info(2, 1, 1, [])) == .stereo)
        #expect(NvstAudioLayout(info(2, 0, 0, [])) == .stereo)
    }

    @Test func otherShapesAreRefused() {
        #expect(NvstAudioLayout(info(4, 2, 2, [0, 1, 2, 3])) == nil)          // not 2, 6 or 8 channels
        #expect(NvstAudioLayout(info(6, 4, 1, [0, 4, 1, 5, 2, 3])) == nil)    // streams + coupled is not 6
        #expect(NvstAudioLayout(info(6, 4, 2, [0, 4, 1, 5, 2])) == nil)       // one mapping entry short
        #expect(NvstAudioLayout(info(6, 4, 2, [0, 4, 1, 6, 2, 3])) == nil)    // entry names a seventh channel
        #expect(NvstAudioLayout(info(6, 2, 4, [0, 4, 1, 5, 2, 3])) == nil)    // more coupled than streams
    }

    /// Stereo must hand the decoder the cookie it has always had.
    @Test func theStereoCookieIsUnchanged() {
        #expect(hex(NvstAudioLayout.stereo.opusHeadCookie) == "4f707573486561640102000080bb0000000000")
    }

    /// RFC 7845 mapping family 1: stream count, coupled count, then the table.
    @Test func aSurroundCookieCarriesTheMappingTable() {
        #expect(hex(NvstAudioLayout.surround51.opusHeadCookie)
                == "4f707573486561640106000080bb00000000" + "010402" + "000401050203")
        #expect(hex(NvstAudioLayout.surround71.opusHeadCookie)
                == "4f707573486561640108000080bb00000000" + "010503" + "0006010702030405")
    }

    @Test func labelsAndSpeakers() {
        #expect(NvstAudioLayout.stereo.label == "Stereo")
        #expect(NvstAudioLayout.surround51.label == "5.1")
        #expect(NvstAudioLayout.surround71.label == "7.1")
        #expect(NvstAudioLayout.stereo.speakers == [.frontLeft, .frontRight])
        #expect(NvstAudioLayout.surround51.speakers
                == [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight])
        #expect(NvstAudioLayout.surround71.speakers.count == 8)
        #expect(Set(NvstAudioLayout.surround71.speakers).count == 8)
    }
}
