import Foundation
import Testing
@testable import VideoEngine

struct RemuxSessionTests {
    @Test func remuxesAFileIntoAFinishedPlaylist() async throws {
        let fixture = try Fixture.url("h264-aac.mkv")
        let session = RemuxSession(sourceFactory: { try FileRangeSource(fileURL: fixture) })
        defer { session.stop() }
        // Only catches a hung run: simulator hosts have frozen test processes for over 10 s.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            session.stop()
        }
        defer { watchdog.cancel() }
        let playlistURL = try session.start()

        var sampleEntry: String?
        var origin: TimeInterval?
        var finished = false
        events: for await event in session.events {
            switch event {
            case .headerWritten(_, let entry):
                sampleEntry = entry
            case .timeline(let value):
                origin = value
            case .finished:
                finished = true
                break events
            case .failed(let error, _):
                Issue.record("remux failed: \(error)")
                break events
            case .stopped:
                break events
            case .opened, .progress:
                continue
            }
        }
        #expect(sampleEntry == "avc1")
        #expect(finished)
        // The fixture's streams start within a frame of the movie's start.
        #expect(abs(try #require(origin)) < 0.05)
        #expect(session.timelineOrigin == origin)

        let (master, _) = try await URLSession.shared.data(from: playlistURL)
        let variant = String(decoding: master, as: UTF8.self)
        #expect(playlistURL.lastPathComponent == "master.m3u8")
        #expect(variant.contains("CODECS=\"avc1."))
        #expect(variant.contains("RESOLUTION=160x90"))
        #expect(variant.contains("VIDEO-RANGE=SDR"))

        let (media, _) = try await URLSession.shared.data(from: playlistURL.deletingLastPathComponent().appendingPathComponent("index.m3u8"))
        let playlist = String(decoding: media, as: UTF8.self)
        #expect(playlist.contains("#EXT-X-TARGETDURATION:10"))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"media.mp4\",BYTERANGE="))
        // One segment per keyframe: the fixture has keyframes 1 s apart.
        #expect(playlist.components(separatedBy: "#EXTINF:").count - 1 == 3)
        #expect(playlist.contains("#EXT-X-ENDLIST"))
    }

    @Test func remuxesHDR10AsHvc1WithAPQRange() async throws {
        let fixture = try Fixture.url("hevc10-opus-srt.mkv")
        let session = RemuxSession(sourceFactory: { try FileRangeSource(fileURL: fixture) })
        defer { session.stop() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            session.stop()
        }
        defer { watchdog.cancel() }
        let playlistURL = try session.start()
        var sampleEntry: String?
        events: for await event in session.events {
            switch event {
            case .headerWritten(_, let entry): sampleEntry = entry
            case .finished, .stopped: break events
            case .failed(let error, _):
                Issue.record("remux failed: \(error)")
                break events
            default: continue
            }
        }
        #expect(sampleEntry == "hvc1")
        let (master, _) = try await URLSession.shared.data(from: playlistURL)
        let variant = String(decoding: master, as: UTF8.self)
        #expect(variant.contains("CODECS=\"hvc1.2."))
        #expect(variant.contains("VIDEO-RANGE=PQ"))
        // Opus is not proven in AVPlayer, so it is re-encoded to AAC-LC.
        #expect(variant.contains(",mp4a.40.2\""))
    }

    @Test func servesTextSubtitlesAsWebVTTRenditions() async throws {
        let fixture = try Fixture.url("hevc10-opus-srt.mkv")
        let session = RemuxSession(sourceFactory: { try FileRangeSource(fileURL: fixture) })
        defer { session.stop() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            session.stop()
        }
        defer { watchdog.cancel() }
        let base = try session.start().deletingLastPathComponent()
        events: for await event in session.events {
            switch event {
            case .finished, .stopped: break events
            case .failed(let error, _):
                Issue.record("remux failed: \(error)")
                break events
            default: continue
            }
        }
        func text(_ path: String) async throws -> String {
            String(decoding: try await URLSession.shared.data(from: base.appendingPathComponent(path)).0, as: UTF8.self)
        }
        #expect(session.subtitleStreams.map(\.name) == ["English"])
        let master = try await text("master.m3u8")
        #expect(master.contains("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English\",LANGUAGE=\"en\""))
        #expect(master.contains("SUBTITLES=\"subs\""))
        let playlist = try await text("subs/0/index.m3u8")
        #expect(playlist.contains("\n0.vtt\n#EXT-X-ENDLIST"))
        let cues = try await text("subs/0/0.vtt")
        #expect(cues.hasPrefix("WEBVTT\n"))
        #expect(cues.contains("Hello"))
        #expect(cues.contains("World"))
    }
}
