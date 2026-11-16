import Foundation

/// Plain sentences for the stream screens. The raw protocol text never reaches the screen and the
/// advice never points at a setting that does not exist on Apple TV.
enum TVStreamFailureMessage {
    static let noEndpoint = "This session has no native streaming endpoint. End it and start the game again."
    static let cannotReach = "Could not reach your gaming rig. Check that your Apple TV is online, then try again."
    static let connectionLost = "The connection to your gaming rig was lost. Try again."
    static let videoStopped = "The video from your gaming rig stopped arriving. Try again."
    static let unsupported = "This stream type is not supported on Apple TV. End the session and start the game again."
    static let audio = "Sound could not start on this Apple TV. Try again."
    static let generic = "The stream stopped unexpectedly. Try again."

    /// Rules are tried in order; the first one whose text is contained in the raw reason wins.
    private static let rules: [(needles: [String], message: String?)] = [
        (["no native streaming endpoint"], noEndpoint),
        // Already plain, and the codec name is part of it, so the raw text is kept.
        (["hardware decoding is unavailable on this apple tv"], nil),
        // Stream types this device cannot decode.
        (["4:4:4", "requires a hardware video decoder"], unsupported),
        // Audio.
        (["audio output could not start", "could not start audio", "audio/control setup"], audio),
        // The video stopped, or could not be decoded.
        (["video stopped arriving", "decoder rejected", "decompression session", "format description",
          "wrap the access unit", "build a sample buffer", "has not delivered a keyframe"], videoStopped),
        // Was running, then dropped.
        (["dtls", "sctp", "usrsctp", "control connection is closed", "connection is closed",
          "could not send", "could not receive", "connection reset", "broken pipe",
          "network connection was lost"], connectionLost),
        // Never reached the rig, or the handshake was refused.
        (["control did not connect", "connect failed", "upgrade rejected", "sec-websocket-accept",
          "timed out", "rtsp ", "udp reservation", "could not bind", "socket error",
          "offline", "not connected to the internet", "could not connect"], cannotReach),
    ]

    static func plain(_ raw: String) -> String {
        let text = raw.lowercased()
        for rule in rules where rule.needles.contains(where: text.contains) {
            return rule.message ?? raw
        }
        return generic
    }
}

/// The connecting screen's progress line, in place of the handshake step names.
enum TVStreamProgress {
    static let connecting = "Connecting to your rig…"
    static let settingUp = "Setting up video and sound…"
    static let starting = "Starting the stream…"

    static func line(for stage: NvstRtspStage) -> String {
        switch stage {
        case .connecting, .upgrading, .options, .describe: connecting
        case .setup, .preparingVideo, .preparingBundle: settingUp
        case .announce, .play: starting
        }
    }
}
