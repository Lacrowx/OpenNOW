import CoreVideo
import Testing
@testable import OpenNOWiOS

/// Which decoded surface the NVST decoder asks VideoToolbox for.
///
/// Measured on an Apple TV 4K (AppleTV18,1) on 2026-11-17 with a 2560x1440 120 fps 10-bit
/// stream that signals video range: asking for the full-range surface took 5.4 ms a frame for
/// 4:2:0 (HEVC and AV1 alike) and 7.5 ms for 4:4:4; asking for the video-range surface took
/// 3.2 ms and 5.3 ms. The request that does not match the stream's range costs about 2.2 ms.
struct NvstDecoderOutputFormatTests {
    typealias Decoder = NvstVideoToolboxDecoder

    static func format(_ chroma: Decoder.BitstreamFormat.Chroma, bitDepth: Int) -> Decoder.BitstreamFormat {
        var format = Decoder.BitstreamFormat()
        format.chroma = chroma
        format.bitDepth = bitDepth
        return format
    }

    @Test func aVideoRangeTenBit420StreamIsAskedForItsOwnRangeFirst() {
        let requests = Decoder.outputPixelFormatRequests(for: Self.format(.yuv420, bitDepth: 10),
                                                         requiresTenBit444: false, sourceIsFullRange: false)
        #expect(requests == [[kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
                             [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]])
    }

    @Test func aFullRangeTenBit420StreamIsAskedForItsOwnRangeFirst() {
        let requests = Decoder.outputPixelFormatRequests(for: Self.format(.yuv420, bitDepth: 10),
                                                         requiresTenBit444: false, sourceIsFullRange: true)
        #expect(requests == [[kCVPixelFormatType_420YpCbCr10BiPlanarFullRange],
                             [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]])
    }

    @Test func anEightBit420StreamIsAskedForItsOwnRangeFirst() {
        let video = Decoder.outputPixelFormatRequests(for: Self.format(.yuv420, bitDepth: 8),
                                                      requiresTenBit444: false, sourceIsFullRange: false)
        #expect(video == [[kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
                          [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]])
        let full = Decoder.outputPixelFormatRequests(for: Self.format(.yuv420, bitDepth: 8),
                                                     requiresTenBit444: false, sourceIsFullRange: true)
        #expect(full == [[kCVPixelFormatType_420YpCbCr8BiPlanarFullRange],
                         [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]])
    }

    /// A 4:4:4 stream that was not asked for strictly keeps its fall-back to 4:2:0, and every
    /// layout is still tried in the stream's own range before the other one.
    @Test func aTenBit444StreamKeepsItsLayoutBeforeFallingBackTo420() {
        let requests = Decoder.outputPixelFormatRequests(for: Self.format(.yuv444, bitDepth: 10),
                                                         requiresTenBit444: false, sourceIsFullRange: false)
        #expect(requests == [[kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange],
                             [kCVPixelFormatType_444YpCbCr10BiPlanarFullRange],
                             [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
                             [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]])
    }

    @Test func aTenBitStreamIsNeverAskedForAnEightBitSurface() {
        for chroma in [Decoder.BitstreamFormat.Chroma.yuv420, .yuv422, .yuv444] {
            for fullRange in [false, true] {
                let requests = Decoder.outputPixelFormatRequests(for: Self.format(chroma, bitDepth: 10),
                                                                 requiresTenBit444: false, sourceIsFullRange: fullRange)
                #expect(requests.joined().allSatisfy { NativeStreamTenBitSurface.chroma($0) != nil })
            }
        }
    }

    /// Strict 4:4:4 is unchanged: both ranges offered together, the stream's own first.
    @Test func strict444StillOffersBothRangesTogether() {
        let requests = Decoder.outputPixelFormatRequests(for: Self.format(.yuv444, bitDepth: 10),
                                                         requiresTenBit444: true, sourceIsFullRange: false)
        #expect(requests == [[kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange],
                             [kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange],
                             [kCVPixelFormatType_444YpCbCr10BiPlanarFullRange]])
    }
}
