import XCTest
@testable import OpenNOWiOS

final class TVStreamFailureMessageTests: XCTestCase {
    private func assertPlain(_ raw: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(TVStreamFailureMessage.plain(raw), expected, raw, file: file, line: line)
    }

    func testKeepsTheClearMessages() {
        let endpoint = "This session has no native streaming endpoint. End it and start the game again."
        assertPlain(endpoint, endpoint)
        assertPlain("H265 hardware decoding is unavailable on this Apple TV.", "H265 hardware decoding is unavailable on this Apple TV.")
    }

    func testVideoStopped() {
        assertPlain("Native NVST video stopped arriving or decoding. Switch off the experimental receiver to use the standard connection.", TVStreamFailureMessage.videoStopped)
        assertPlain("NVST decoder rejected a frame (OSStatus -12909).", TVStreamFailureMessage.videoStopped)
        assertPlain("NVST decoder could not create a decompression session (OSStatus -12911).", TVStreamFailureMessage.videoStopped)
    }

    func testControlNeverConnected() {
        assertPlain("Native NVST control did not connect. Switch off the experimental receiver to use the standard connection.", TVStreamFailureMessage.cannotReach)
    }

    func testRigUnreachable() {
        assertPlain("NVST RTSPS connect failed: Connection refused", TVStreamFailureMessage.cannotReach)
        assertPlain("NVST RTSPS WebSocket upgrade rejected with HTTP 403.", TVStreamFailureMessage.cannotReach)
        assertPlain("NVST RTSPS OPTIONS timed out.", TVStreamFailureMessage.cannotReach)
        assertPlain("RTSP DESCRIBE failed: 454 Session Not Found", TVStreamFailureMessage.cannotReach)
        assertPlain("NVST UDP reservation failed: address in use", TVStreamFailureMessage.cannotReach)
    }

    func testConnectionLost() {
        assertPlain("Native NVST DTLS failed: The DTLS handshake did not complete before its deadline.", TVStreamFailureMessage.connectionLost)
        assertPlain("usrsctp could not start the SCTP association: refused", TVStreamFailureMessage.connectionLost)
        assertPlain("The NVST RTSPS control connection is closed.", TVStreamFailureMessage.connectionLost)
        assertPlain("The DTLS bundle could not receive a datagram: x", TVStreamFailureMessage.connectionLost)
    }

    func testUnsupportedStreamType() {
        assertPlain("Requested 10-bit 4:4:4, but the host delivered 4:2:0. Select 10-bit 4:2:0 to continue.", TVStreamFailureMessage.unsupported)
        assertPlain("Native NVST requires a hardware video decoder on this device.", TVStreamFailureMessage.unsupported)
    }

    func testAudio() {
        assertPlain("Native NVST audio output could not start (OSStatus 561015905)", TVStreamFailureMessage.audio)
    }

    func testUnknownFallsBackToGenericAndNeverMentionsSettings() {
        assertPlain("DESCRIBE did not advertise a video media control URI.", TVStreamFailureMessage.generic)
        assertPlain("", TVStreamFailureMessage.generic)
        let all = [TVStreamFailureMessage.cannotReach, TVStreamFailureMessage.connectionLost, TVStreamFailureMessage.videoStopped,
                   TVStreamFailureMessage.unsupported, TVStreamFailureMessage.audio, TVStreamFailureMessage.generic]
        for message in all {
            XCTAssertFalse(message.lowercased().contains("experimental"), message)
            XCTAssertFalse(message.lowercased().contains("switch off"), message)
            XCTAssertFalse(message.lowercased().contains("select 10-bit"), message)
        }
    }

    func testProgressLinesArePlain() {
        for stage in [NvstRtspStage.connecting, .upgrading, .options, .describe, .setup, .preparingVideo,
                      .preparingBundle, .announce, .play] {
            let line = TVStreamProgress.line(for: stage)
            XCTAssertFalse(line.contains(stage.rawValue) && stage.rawValue == stage.rawValue.uppercased(), line)
        }
        XCTAssertEqual(TVStreamProgress.line(for: .describe), "Connecting to your rig…")
        XCTAssertEqual(TVStreamProgress.line(for: .setup), "Setting up video and sound…")
        XCTAssertEqual(TVStreamProgress.line(for: .play), "Starting the stream…")
    }
}
