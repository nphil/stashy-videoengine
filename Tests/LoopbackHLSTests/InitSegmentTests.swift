import Foundation
import Testing
@testable import LoopbackHLS

struct InitSegmentTests {
    @Test func readsTheHandlerAndSampleEntryOfEachTrack() throws {
        let segment = try #require(InitSegment(data: MP4.initSegment(trackID: 1, timescale: 90_000, sampleEntry: "hev1")))
        #expect(segment.tracks == [InitSegment.Track(handler: "vide", sampleEntry: "hev1")])
        #expect(segment.videoSampleEntry == "hev1")
    }
}
