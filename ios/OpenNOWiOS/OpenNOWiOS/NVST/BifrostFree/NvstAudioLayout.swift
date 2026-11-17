import Foundation

/// A speaker position.
public enum NvstSpeaker: Hashable, Sendable {
    case frontLeft, frontRight, frontCenter, lowFrequency, backLeft, backRight, sideLeft, sideRight
}

/// The channel layout of the seat's game audio: one Opus multistream configuration, and the
/// speaker each decoded channel belongs to.
///
/// The seat states the configuration in its `0x0408` message (`NvstAudioSurroundInfo`). The two
/// surround layouts below are the official client's own, from the strings in `libBifrost2.dylib`:
/// `channel_mapping=0,4,1,5,2,3;num_streams=4;coupled_streams=2` and
/// `channel_mapping=0,6,1,7,2,3,4,5;num_streams=5;coupled_streams=3`.
public struct NvstAudioLayout: Equatable, Sendable {
    public let channels: Int
    public let streams: Int
    public let coupledStreams: Int
    /// For each decoded channel, the coded channel it is read from (RFC 7845 section 5.1.1).
    public let mapping: [UInt8]

    public static let stereo = NvstAudioLayout(unchecked: 2, streams: 1, coupledStreams: 1, mapping: [0, 1])
    public static let surround51 = NvstAudioLayout(unchecked: 6, streams: 4, coupledStreams: 2, mapping: [0, 4, 1, 5, 2, 3])
    public static let surround71 = NvstAudioLayout(unchecked: 8, streams: 5, coupledStreams: 3,
                                                   mapping: [0, 6, 1, 7, 2, 3, 4, 5])

    /// The official layout for a channel count, nil for a count the seat does not offer.
    public static func official(channels: Int) -> NvstAudioLayout? {
        switch channels {
        case 2: .stereo
        case 6: .surround51
        case 8: .surround71
        default: nil
        }
    }

    private init(unchecked channels: Int, streams: Int, coupledStreams: Int, mapping: [UInt8]) {
        self.channels = channels
        self.streams = streams
        self.coupledStreams = coupledStreams
        self.mapping = mapping
    }

    /// Nil unless the numbers describe a stream the decoder can be set up for: 6 or 8 channels,
    /// one mapping entry per channel, every entry naming a coded channel, and the coded channels
    /// (one per stream plus one per coupled stream) adding up to the channel count.
    public init?(channels: Int, streams: Int, coupledStreams: Int, mapping: [UInt8]) {
        guard channels == 6 || channels == 8, streams >= 1, coupledStreams >= 0, coupledStreams <= streams,
              streams + coupledStreams == channels, mapping.count == channels,
              mapping.allSatisfy({ Int($0) < channels }) else { return nil }
        self.init(unchecked: channels, streams: streams, coupledStreams: coupledStreams, mapping: mapping)
    }

    /// The layout the seat announced. Two channels are plain stereo whatever else the message says.
    public init?(_ info: NvstAudioSurroundInfo) {
        if info.channels == 2 {
            self = .stereo
            return
        }
        self.init(channels: Int(info.channels), streams: Int(info.streams),
                  coupledStreams: Int(info.coupledStreams), mapping: info.channelMapping)
    }

    /// The speaker of each decoded channel: the Windows order that the announce's speaker mask
    /// (`0x3F`, `0x63F`) is written in. Not yet confirmed against a live stream.
    private static let speakerOrder: [NvstSpeaker] = [
        .frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight, .sideLeft, .sideRight,
    ]

    public var speakers: [NvstSpeaker] { Array(Self.speakerOrder.prefix(channels)) }

    public var label: String {
        switch channels {
        case 6: "5.1"
        case 8: "7.1"
        default: "Stereo"
        }
    }

    /// RFC 7845's identification header, which the decoder takes as its magic cookie: magic,
    /// version, channel count, pre-skip, input sample rate, output gain, mapping family. Stereo is
    /// family 0; surround is family 1 followed by the stream count, the coupled count and the table.
    public var opusHeadCookie: Data {
        var writer = NvstByteWriter(capacity: 21 + channels)
        writer.bytes(Data("OpusHead".utf8))
        writer.u8(1)
        writer.u8(UInt8(channels))
        writer.zeroes(2)
        writer.u32LE(48_000)
        writer.zeroes(2)
        guard channels > 2 else {
            writer.u8(0)
            return writer.data
        }
        writer.u8(1)
        writer.u8(UInt8(streams))
        writer.u8(UInt8(coupledStreams))
        writer.bytes(mapping)
        return writer.data
    }
}
