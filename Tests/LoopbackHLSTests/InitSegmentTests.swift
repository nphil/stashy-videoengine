import Foundation
import Testing
@testable import LoopbackHLS

struct InitSegmentTests {
    /// hvcC of HEVC Main 10, level 5.1, compatibility flag 2, constraint byte 0xB0.
    private static let main10 = MP4.box("hvcC", Data([1, 0x02, 0x20, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 153]) + Data(count: 10))
    private static let pq = MP4.box("colr", Data("nclx".utf8) + MP4.be16(9) + MP4.be16(16) + MP4.be16(9) + Data([0]))
    /// esds for AAC-LC: ES_Descriptor > DecoderConfigDescriptor (MPEG-4 audio) > AudioSpecificConfig.
    private static let aacLC = MP4.box("esds", Data([
        0, 0, 0, 0, 0x03, 25, 0, 1, 0,
        0x04, 17, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0x05, 2, 0x11, 0x90, 0x06, 1, 0x02,
    ]))

    /// A Dolby Vision configuration record: profile and level bits, RPU and base layer present.
    private static func dolbyVision(_ type: String, profile: UInt8, level: UInt8, compatibility: UInt8) -> Data {
        MP4.box(type, Data([1, 0, profile << 1 | level >> 5, (level & 0x1F) << 3 | 0x05, compatibility << 4]) + Data(count: 19))
    }

    @Test func readsTheHandlerAndSampleEntryOfEachTrack() throws {
        let data = MP4.initSegment(MP4.trak(entry: "hev1", fields: MP4.visualFields()))
        let segment = try #require(InitSegment(data: data))
        #expect(segment.tracks == [InitSegment.Track(handler: "vide", sampleEntry: "hev1")])
        #expect(segment.videoSampleEntry == "hev1")
    }

    @Test func hdr10WithDolbyVisionProfile8DescribesBothReadings() throws {
        let video = MP4.trak(entry: "hvc1", fields: MP4.visualFields(width: 3840, height: 2160),
                             children: Self.main10 + Self.pq + Self.dolbyVision("dvvC", profile: 8, level: 6, compatibility: 1))
        let audio = MP4.trak(trackID: 2, timescale: 48_000, handler: "soun", entry: "mp4a",
                             fields: MP4.audioFields, children: Self.aacLC)
        let segment = try #require(InitSegment(data: MP4.initSegment(video, audio)))
        let variant = segment.variant(uri: "index.m3u8", bandwidth: 24_000_000, averageBandwidth: 20_000_000,
                                      frameRate: 24_000.0 / 1001)
        #expect(HLSMultivariantPlaylist(variants: [variant]).render() == """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-STREAM-INF:BANDWIDTH=24000000,AVERAGE-BANDWIDTH=20000000,VIDEO-RANGE=PQ,\
            CODECS="hvc1.2.4.L153.B0,mp4a.40.2",SUPPLEMENTAL-CODECS="dvh1.08.06/db1p",\
            RESOLUTION=3840x2160,FRAME-RATE=23.976
            index.m3u8

            """)
    }

    @Test func dolbyVisionProfile5IsItsOwnCodecInPQ() throws {
        let video = MP4.trak(entry: "dvh1", fields: MP4.visualFields(width: 1920, height: 1080),
                             children: Self.main10 + Self.dolbyVision("dvcC", profile: 5, level: 6, compatibility: 0))
        let variant = try #require(InitSegment(data: MP4.initSegment(video))).variant(uri: "index.m3u8", bandwidth: 1)
        #expect(variant.codecs == ["dvh1.05.06"])
        #expect(variant.supplementalCodecs.isEmpty)
        #expect(variant.videoRange == .pq)
    }

    @Test func rangeFallsBackToTheBitstreamWithoutAColourBox() throws {
        let video = MP4.trak(entry: "avc1", fields: MP4.visualFields(width: 1280, height: 720),
                             children: MP4.box("avcC", Data([1, 0x64, 0x00, 0x28, 0xFF])))
        let audio = MP4.trak(trackID: 2, handler: "soun", entry: "ec-3", fields: MP4.audioFields)
        let segment = try #require(InitSegment(data: MP4.initSegment(video, audio)))
        #expect(segment.variant(uri: "a", bandwidth: 1).codecs == ["avc1.640028", "ec-3"])
        #expect(segment.variant(uri: "a", bandwidth: 1).videoRange == .sdr)
        #expect(segment.variant(uri: "a", bandwidth: 1, transferFallback: 18).videoRange == .hlg)
    }
}
