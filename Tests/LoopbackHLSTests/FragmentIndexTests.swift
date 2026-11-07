import Foundation
import Testing
@testable import LoopbackHLS

struct FragmentIndexTests {
    private let initSegment = MP4.initSegment(trackID: 1, timescale: 1000)
    private let fragments = [0, 2000, 4000].map { MP4.fragment(trackID: 1, decodeTime: UInt64($0), payload: 100) }

    @Test func listsFragmentsOnceFinalAndEndsWhenComplete() throws {
        let bytes = initSegment + fragments.reduce(Data(), +)
        let file = try GrowingFile(bytes, available: Int64(bytes.count))
        let index = FragmentIndex(fileURL: file.url, available: { file.available },
                                  isComplete: { file.isComplete }, totalDuration: 5.5)

        let initLength = Int64(initSegment.count)
        let fragmentLength = Int64(fragments[0].count)
        let growing = try #require(index.playlist(mediaName: "media.mp4")).split(separator: "\n").map(String.init)
        #expect(growing == [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:2",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:EVENT",
            "#EXT-X-MAP:URI=\"media.mp4\",BYTERANGE=\"\(initLength)@0\"",
            "#EXTINF:2.000,",
            "#EXT-X-BYTERANGE:\(fragmentLength)@\(initLength)",
            "media.mp4",
            "#EXTINF:2.000,",
            "#EXT-X-BYTERANGE:\(fragmentLength)@\(initLength + fragmentLength)",
            "media.mp4",
        ])

        file.update(available: Int64(file.bytes.count), complete: true)
        let complete = try #require(index.playlist(mediaName: "media.mp4")).split(separator: "\n").map(String.init)
        #expect(Array(complete.suffix(4)) == [
            "#EXTINF:1.500,",
            "#EXT-X-BYTERANGE:\(fragmentLength)@\(initLength + 2 * fragmentLength)",
            "media.mp4",
            "#EXT-X-ENDLIST",
        ])
        let total = complete.filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).dropLast()) }
            .reduce(0, +)
        #expect(abs(total - 5.5) < 0.001)
    }

    @Test func waitsForInitAndOneFinalFragment() throws {
        let file = try GrowingFile(initSegment + fragments[0] + fragments[1], available: 0)
        let index = FragmentIndex(fileURL: file.url, available: { file.available },
                                  isComplete: { file.isComplete }, totalDuration: 5.5)

        file.update(available: Int64(initSegment.count - 10), complete: false)
        #expect(index.playlist(mediaName: "media.mp4") == nil)
        // The next moof is only partly written, so the first fragment's end is not known yet.
        file.update(available: Int64(initSegment.count + fragments[0].count + 40), complete: false)
        #expect(index.playlist(mediaName: "media.mp4") == nil)
        file.update(available: Int64(file.bytes.count), complete: false)
        #expect(index.playlist(mediaName: "media.mp4")?.contains("#EXT-X-BYTERANGE") == true)
    }
}
