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
        var finished = false
        events: for await event in session.events {
            switch event {
            case .headerWritten(_, let entry):
                sampleEntry = entry
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

        let (data, _) = try await URLSession.shared.data(from: playlistURL)
        let playlist = String(decoding: data, as: UTF8.self)
        #expect(playlist.contains("#EXT-X-MAP:URI=\"media.mp4\""))
        #expect(playlist.contains("#EXT-X-ENDLIST"))
    }
}
