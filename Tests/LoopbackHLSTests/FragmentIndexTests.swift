import Foundation
import Testing
@testable import LoopbackHLS

struct FragmentIndexTests {
    @Test func listsSealedSegmentsAsContiguousByteRanges() throws {
        let index = FragmentIndex(mediaName: "media.mp4", targetDuration: 10)
        #expect(index.playlist() == nil)
        index.setInitSegment(length: 1000)
        #expect(index.playlist() == nil)

        index.seal(endOffset: 5000, duration: 2.002)
        index.seal(endOffset: 5000, duration: 1)
        let growing = try #require(index.playlist()).split(separator: "\n").map(String.init)
        #expect(growing == [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:10",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:EVENT",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"media.mp4\",BYTERANGE=\"1000@0\"",
            "#EXTINF:2.002,",
            "#EXT-X-BYTERANGE:4000@1000",
            "media.mp4",
        ])

        index.seal(endOffset: 9000, duration: 1.5)
        index.finish()
        index.seal(endOffset: 12000, duration: 2)
        let ended = try #require(index.playlist()).split(separator: "\n").map(String.init)
        #expect(Array(ended.suffix(4)) == ["#EXTINF:1.500,", "#EXT-X-BYTERANGE:4000@5000", "media.mp4", "#EXT-X-ENDLIST"])
        #expect(index.segmentCount == 2)
    }
}
