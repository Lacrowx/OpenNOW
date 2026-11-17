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

    /// The line a live seat's DESCRIBE carried on 2026-11-17: one entry per channel count, each
    /// the channel count, stream count and coupled count, then one mapping digit per channel.
    @Test func theSeatsDescribeListsItsLayouts() throws {
        let describe = """
        m=audio 0 RTP/AVP 96 97
        a=fmtp:97 surround-params=85306123457
        a=nv-audio-surround-opus-params: 20000000000;32102100000;42201230000;53204123000;64204123500;74304123560;85306123457;
        a=rtpmap:97 opus/16000/2
        """
        let layouts = NvstAudioLayout.seatLayouts(describe: describe)
        let fiveOne = try #require(layouts.first { $0.channels == 6 })
        #expect(fiveOne.streams == 4 && fiveOne.coupledStreams == 2 && fiveOne.mapping == [0, 4, 1, 2, 3, 5])
        let sevenOne = try #require(layouts.first { $0.channels == 8 })
        #expect(sevenOne.streams == 5 && sevenOne.coupledStreams == 3 && sevenOne.mapping == [0, 6, 1, 2, 3, 4, 5, 7])
        #expect(layouts.count == 2)   // stereo and the odd counts are not surround layouts this client plays
    }

    @Test func aDescribeWithoutTheLineOrWithBrokenEntriesListsNothing() {
        #expect(NvstAudioLayout.seatLayouts(describe: "a=x-nv-audio.surround.enable:0").isEmpty)
        #expect(NvstAudioLayout.seatLayouts(describe: "a=nv-audio-surround-opus-params: 64204;8530612345x;;").isEmpty)
    }

    @Test func labelsAndSpeakers() {
        #expect(NvstAudioLayout.stereo.label == "Stereo")
        #expect(NvstAudioLayout.surround51.label == "5.1")
        #expect(NvstAudioLayout.surround71.label == "7.1")
        #expect(NvstAudioLayout.stereo.speakers == [.frontLeft, .frontRight])
        #expect(NvstAudioLayout.surround51.speakers
                == [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight])
        #expect(NvstAudioLayout.surround71.speakers
                == [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight, .sideLeft, .sideRight])
    }

    /// The seat's own tables decode its channels in the order measured on a live 7.1 stream on
    /// 2026-11-17 (stereo menus only on the first two, the last silent, the side pair moving with
    /// the front pair); the official client's tables reorder the same stream to the Windows order.
    @Test func theSeatsTablesGiveTheMeasuredOrder() throws {
        let layouts = NvstAudioLayout.seatLayouts(describe: "a=nv-audio-surround-opus-params: 64204123500;85306123457;")
        #expect(try #require(layouts.first { $0.channels == 6 }).speakers
                == [.frontLeft, .frontRight, .frontCenter, .backLeft, .backRight, .lowFrequency])
        #expect(try #require(layouts.first { $0.channels == 8 }).speakers
                == [.frontLeft, .frontRight, .frontCenter, .backLeft, .backRight, .sideLeft, .sideRight, .lowFrequency])
    }
}
