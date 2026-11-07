import Foundation
import LoopbackHLS
import os
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
        let playlistURL = try await session.start()

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
        let playlistURL = try await session.start()
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
        let base = try await session.start().deletingLastPathComponent()
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

    /// A resumed start over a slow link: once the master playlist answers, a sidecar rendition already
    /// lists the slot under the first video segment. The source stops 8 s past the resume point, so the
    /// run cannot read on and finish before the playlists are read.
    @Test func sidecarSubtitlesCoverTheFirstSegmentOfASlowResumedStart() async throws {
        let fixture = try Fixture.url("h264-aac-60s.mkv")
        // The keyframe at 48 s sits at byte 229_974; the index at the end stays readable.
        let source = try GatedSource(fixture, stopAt: 229_974)
        var options = RemuxOptions()
        options.sidecarSubtitles = [SidecarSubtitles(
            name: "English", language: "en", isDefault: true, isForced: true,
            cues: [SubtitleCue(start: 41, end: 43, text: "Forced")]
        )]
        let session = RemuxSession(sourceFactory: { source }, options: options)
        defer { session.stop() }
        let base = try await session.start(at: 40.5).deletingLastPathComponent()
        let deadline = ContinuousClock.now + .seconds(30)
        while !source.isWaiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(source.isWaiting)

        func text(_ path: String) async throws -> String {
            String(decoding: try await URLSession.shared.data(from: base.appendingPathComponent(path)).0, as: UTF8.self)
        }
        #expect(try await text("master.m3u8").contains("FORCED=YES"))
        #expect(try await text("index.m3u8").contains("#EXTINF"))
        let subtitles = try await text("subs/0/index.m3u8")
        #expect(subtitles.contains("\n0.vtt\n"))
        #expect(!subtitles.contains("#EXT-X-ENDLIST"))
        #expect(try await text("subs/0/0.vtt").contains("Forced"))
    }
}

/// A file whose bytes from `stopAt` on, short of the last 16 KiB, never arrive: a link that stalls
/// past the resume point. Reads wait there until cancelled.
private final class GatedSource: ByteRangeSource {
    private let base: FileRangeSource
    private let stopAt: Int64
    private let size: Int64
    private let waiting = OSAllocatedUnfairLock(initialState: false)
    private let wake = DispatchSemaphore(value: 0)

    init(_ url: URL, stopAt: Int64) throws {
        base = try FileRangeSource(fileURL: url)
        self.stopAt = stopAt
        size = try base.length() ?? 0
    }

    var logName: String { "gated-" + base.logName }
    var isWaiting: Bool { waiting.withLock { $0 } }
    func length() throws -> Int64? { size }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let tail = size - (16 << 10)
        if offset >= stopAt, offset < tail {
            waiting.withLock { $0 = true }
            wake.wait()
            throw CancellationError()
        }
        let end = offset < stopAt ? min(stopAt, tail) : size
        let count = min(buffer.count, Int(max(0, end - offset)))
        return try base.read(at: offset, into: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count]))
    }

    func cancel() {
        base.cancel()
        wake.signal()
    }
}
