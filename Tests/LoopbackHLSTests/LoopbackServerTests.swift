import Foundation
import Testing
@testable import LoopbackHLS

struct LoopbackServerTests {
    private static let bytes = Data((0..<1000).map { UInt8($0 % 251) })

    @Test func servesWrittenRangesOfAGrowingFile() async throws {
        let file = try GrowingFile(Self.bytes, available: 600)
        let server = LoopbackServer(routes: [file.route("/media.mp4")], waitTimeout: 0.1)
        let base = try await server.start()
        defer { server.stop() }

        let partial = try await RawHTTP.get(base, "/media.mp4", range: "bytes=100-199")
        #expect(partial.status == 206)
        #expect(partial.headers["content-range"] == "bytes 100-199/*")
        #expect(partial.headers["content-length"] == "100")
        #expect(partial.body == Self.bytes[100..<200])

        let unwritten = try await RawHTTP.get(base, "/media.mp4", range: "bytes=700-799")
        #expect(unwritten.status == 416)

        file.update(available: 1000, complete: true)
        let tail = try await RawHTTP.get(base, "/media.mp4", range: "bytes=900-")
        #expect(tail.status == 206)
        #expect(tail.headers["content-range"] == "bytes 900-999/1000")
        #expect(tail.body == Self.bytes[900...])

        let past = try await RawHTTP.get(base, "/media.mp4", range: "bytes=1000-")
        #expect(past.status == 416)
        #expect(past.headers["content-range"] == "bytes */1000")
    }

    @Test func waitingRequestWakesWhenContentChanges() async throws {
        let file = try GrowingFile(Self.bytes, available: 500)
        let server = LoopbackServer(routes: [file.route("/media.mp4")], waitTimeout: 5)
        let base = try await server.start()
        defer { server.stop() }

        async let response = RawHTTP.get(base, "/media.mp4", range: "bytes=600-699")
        try await Task.sleep(for: .milliseconds(50))
        file.update(available: 1000, complete: false)
        server.contentChanged()

        let reply = try await response
        #expect(reply.status == 206)
        #expect(reply.body == Self.bytes[600..<700])
    }

    @Test func answersPlaylistsAndUnknownPaths() async throws {
        let server = LoopbackServer(routes: [
            LoopbackRoute(path: "/pending.m3u8", .playlist { nil }),
            LoopbackRoute(path: "/index.m3u8", .playlist { "#EXTM3U\n" }),
        ], waitTimeout: 0.1)
        let base = try await server.start()
        defer { server.stop() }

        #expect(try await RawHTTP.get(base, "/pending.m3u8").status == 503)
        let playlist = try await RawHTTP.get(base, "/index.m3u8?session=1")
        #expect(playlist.status == 200)
        #expect(playlist.headers["content-type"] == "application/vnd.apple.mpegurl")
        #expect(playlist.body == Data("#EXTM3U\n".utf8))
        #expect(try await RawHTTP.get(base, "/other").status == 404)
        #expect(server.recentRequests().count == 3)
    }
}
