import Foundation
import Testing
@testable import LoopbackHLS

struct FragmentSealerTests {
    @Test func sealsEachFragmentWhenItsMediaDataEnds() throws {
        let movie = MP4.movie(
            traks: [
                MP4.trak(trackID: 1, timescale: 48_000, handler: "soun", entry: "mp4a", fields: MP4.audioFields),
                MP4.trak(trackID: 2, timescale: 90_000, handler: "vide", entry: "avc1", fields: MP4.visualFields()),
            ],
            trex: [MP4.trex(trackID: 1, defaultDuration: 1024), MP4.trex(trackID: 2, defaultDuration: 3000)]
        )
        // The audio runs 1.003 s; the segment lasts as long as its video.
        let first = MP4.fragment(
            MP4.traf(trackID: 1, durations: Array(repeating: 1024, count: 47)),
            MP4.traf(trackID: 2, durations: Array(repeating: 3000, count: 30)),
            mediaBytes: 500
        )
        // No duration per sample or in the tfhd: the trex default applies.
        let second = MP4.fragment(MP4.traf(trackID: 2, count: 45), mediaBytes: 300)
        let file = movie + first + second
        let index = FragmentIndex(mediaName: "media.mp4", targetDuration: 10)
        let sealer = FragmentSealer(index: index)

        // Seven-byte writes split box headers and payloads alike.
        Self.write(file.dropLast(), to: sealer)
        #expect(sealer.initSegment == movie)
        #expect(sealer.sealedSegments == 1)
        Self.write(file.suffix(1), to: sealer)

        let lines = try #require(index.playlist()).split(separator: "\n").map(String.init)
        #expect(lines.contains("#EXT-X-MAP:URI=\"media.mp4\",BYTERANGE=\"\(movie.count)@0\""))
        #expect(Array(lines.suffix(6)) == [
            "#EXTINF:1.000,", "#EXT-X-BYTERANGE:\(first.count)@\(movie.count)", "media.mp4",
            "#EXTINF:1.500,", "#EXT-X-BYTERANGE:\(second.count)@\(movie.count + first.count)", "media.mp4",
        ])
        #expect(index.longestSegment == 1.5)
    }

    @Test func readsSixtyFourBitSizesAndFragmentDefaults() throws {
        let movie = MP4.movie(traks: [
            MP4.trak(trackID: 7, timescale: 1000, handler: "vide", entry: "hvc1", fields: MP4.visualFields()),
        ])
        let moof = MP4.box("moof", MP4.traf(trackID: 7, count: 4, defaultDuration: 500))
        let mdat = MP4.largeBox("mdat", Data(count: 40))
        let index = FragmentIndex(mediaName: "media.mp4", targetDuration: 10)
        let sealer = FragmentSealer(index: index)

        Self.write(movie + moof + mdat, to: sealer)

        let lines = try #require(index.playlist()).split(separator: "\n").map(String.init)
        #expect(Array(lines.suffix(3)) == ["#EXTINF:2.000,", "#EXT-X-BYTERANGE:\(moof.count + mdat.count)@\(movie.count)", "media.mp4"])
    }

    private static func write(_ data: Data, to sealer: FragmentSealer) {
        data.withUnsafeBytes { bytes in
            for start in stride(from: 0, to: bytes.count, by: 7) {
                sealer.append(UnsafeRawBufferPointer(rebasing: bytes[start..<min(start + 7, bytes.count)]))
            }
        }
    }
}
