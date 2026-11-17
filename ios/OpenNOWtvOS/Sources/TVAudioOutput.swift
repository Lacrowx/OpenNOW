import AVFAudio
import Foundation

/// How many audio channels the connected output carries, as a stream may ask the seat for them.
enum TVAudioOutput {
    static var channels: Int {
        channels(carried: AVAudioSession.sharedInstance().maximumOutputNumberOfChannels,
                 forced: forcedChannels, canDecodeSurround: canDecodeSurround)
    }

    /// A forced count (Debug builds) stands in for what the output reports. Without a decoder for
    /// the surround layouts, the answer is never more than stereo.
    static func channels(carried: Int, forced: Int?, canDecodeSurround: Bool) -> Int {
        let count = forced ?? carried
        return canDecodeSurround ? count : min(count, 2)
    }

    /// Whether this device's Opus decoder accepts the seat's two surround layouts. Built once.
    static let canDecodeSurround: Bool = [NvstAudioLayout.surround51, .surround71].allSatisfy {
        (try? NvstOpusDecoder(layout: $0)) != nil
    }

    /// `--opennow-audio-channels=6` or `=8` (Debug builds): ask for that many channels whatever
    /// the output reports, so decode and fold-down can be tried on a stereo TV.
    private static var forcedChannels: Int? {
        #if DEBUG
        let prefix = "--opennow-audio-channels="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .flatMap { Int($0.dropFirst(prefix.count)) }
        #else
        return nil
        #endif
    }
}
