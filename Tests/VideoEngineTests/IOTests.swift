import Foundation
import Testing
@testable import VideoEngine

struct ContentRangeTests {
    @Test func parsesByteRanges() {
        #expect(ContentRange(header: "bytes 100-199/1000") == ContentRange(first: 100, last: 199, total: 1000))
        #expect(ContentRange(header: "bytes 0-9/*") == ContentRange(first: 0, last: 9, total: nil))
        #expect(ContentRange(header: "bytes */1000") == ContentRange(first: nil, last: nil, total: 1000))
    }

    @Test func rejectsMalformedHeaders() {
        #expect(ContentRange(header: "items 0-9/10") == nil)
        #expect(ContentRange(header: "bytes 9-0/10") == nil)
        #expect(ContentRange(header: "bytes 0-9") == nil)
    }
}

struct HTTPRangeSourceTests {
    private let body = Data((0..<1000).map { UInt8($0 % 251) })

    @Test func servesMatchingPartialContent() throws {
        let source = FakeHTTP.source(FakeHTTP.ranged(body))
        #expect(try source.bytes(at: 100, count: 50) == body.subdata(in: 100..<150))
        #expect(try source.length() == 1000)
    }

    @Test func rejectsPartialContentFromTheWrongOffset() throws {
        let source = FakeHTTP.source { _ in
            .init(status: 206, headers: ["Content-Range": "bytes 0-49/1000"], body: Data(repeating: 1, count: 50))
        }
        let error = #expect(throws: VideoEngineError.self) { try source.bytes(at: 100, count: 50) }
        guard case .unsupportedSource = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func rejectsWholeFileForALaterOffset() throws {
        let source = FakeHTTP.source { _ in .init(status: 200, body: Data(repeating: 1, count: 1000)) }
        let error = #expect(throws: VideoEngineError.self) { try source.bytes(at: 100, count: 50) }
        guard case .unsupportedSource = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func acceptsWholeFileFromTheStart() throws {
        let body = body
        let source = FakeHTTP.source { _ in .init(status: 200, body: body) }
        #expect(try source.bytes(at: 0, count: 10) == body.prefix(10))
    }

    /// An error page must surface as an error, never as video bytes for FFmpeg to parse.
    @Test func reportsRefusalWithoutPassingTheBody() throws {
        let source = FakeHTTP.source { _ in .init(status: 401, body: Data("<html>login</html>".utf8)) }
        #expect(throws: VideoEngineError.sourceUnreachable(status: 401)) { try source.bytes(at: 0, count: 10) }
    }

    @Test func treatsRangeNotSatisfiableAtTheEndAsEndOfFile() throws {
        let source = FakeHTTP.source(FakeHTTP.ranged(body))
        #expect(try source.bytes(at: 1000, count: 10).isEmpty)
    }

    /// A dropped connection is a failure: reporting it as the end would cut the video short.
    @Test func reportsTransportFailureAsAnError() throws {
        let source = FakeHTTP.source { _ in .init(failure: .networkConnectionLost) }
        #expect(throws: VideoEngineError.sourceUnreachable(status: nil)) { try source.bytes(at: 0, count: 10) }
    }

    @Test func cancelStopsReads() throws {
        let source = FakeHTTP.source(FakeHTTP.ranged(body))
        source.cancel()
        #expect(throws: CancellationError.self) { try source.bytes(at: 0, count: 10) }
    }

    @Test func knownLengthNeedsNoRequest() throws {
        // Nothing listens on the discard port, so a request would fail the call.
        let source = HTTPRangeSource(url: URL(string: "http://127.0.0.1:9/video.mkv")!, knownLength: 1234, maxAttempts: 1)
        #expect(try source.length() == 1234)
    }
}

struct FileRangeSourceTests {
    @Test func readsAndEndsAtTheFileSize() throws {
        let url = Fixture.temporaryURL(".bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((0..<100).map { UInt8($0) }).write(to: url)
        let source = try FileRangeSource(fileURL: url)
        #expect(try source.length() == 100)
        #expect(try source.bytes(at: 90, count: 50) == Data((90..<100).map { UInt8($0) }))
        #expect(try source.bytes(at: 100, count: 10).isEmpty)
    }
}
