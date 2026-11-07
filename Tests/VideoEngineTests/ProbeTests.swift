import Foundation
import Testing
@testable import VideoEngine

struct MediaProbeTests {
    @Test func readsStreamDetails() async throws {
        let info = try await MediaProbe.probe(url: Fixture.url("hevc10-opus-srt.mkv"), depth: .full)
        #expect(info.container.hasPrefix("matroska"))
        #expect(abs((info.duration ?? 0) - 2) < 0.1)
        let video = try #require(info.video.first)
        #expect(video.codec == "hevc")
        #expect(video.pixelFormat == "yuv420p10le")
        #expect(video.bitDepth == 10)
        #expect(video.colorTransfer == "smpte2084")
        #expect(video.colorPrimaries == "bt2020")
        #expect(info.audio.map(\.codec) == ["opus"])
        #expect(info.audio.first?.channels == 2)
        let subtitle = try #require(info.subtitles.first)
        #expect(subtitle.codec == "subrip")
        #expect(subtitle.language == "eng")
        #expect(!subtitle.isBitmap)
    }

    @Test func rejectsANonVideoFile() async throws {
        let url = Fixture.temporaryURL(".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a video".utf8).write(to: url)
        await #expect(throws: VideoEngineError.self) { try await MediaProbe.probe(url: url) }
    }
}
