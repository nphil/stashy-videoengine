import Foundation
import os
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
        let source = HTTPRangeSource(url: URL(string: "http://127.0.0.1:9/video.mkv")!, knownLength: 1234, retryWindow: 0)
        #expect(try source.length() == 1234)
    }

    /// How a Matroska file opens: the head, the index at the end, then the head again.
    @Test func keepsTheHeadCachedWhileTheTailIsRead() throws {
        let body = Self.pattern(count: 3 << 20)
        let source = FakeHTTP.source(readAheadBytes: 4 << 20, FakeHTTP.ranged(body))
        _ = try source.bytes(at: 0, count: 64 << 10)
        _ = try source.bytes(at: Int64(body.count - 1000), count: 1000)
        let head = try source.bytes(at: 6498, count: 64 << 10)
        #expect(head == body.subdata(in: 6498..<(6498 + head.count)))
        let requests = source.requestedRanges.sorted { $0.start < $1.start }
        #expect(requests.map(\.start) == [0, Int64(body.count - 1000)])
        #expect(requests.map(\.limit) == [512 << 10, 1000])
    }

    @Test func growsSequentialRequestsAndKeepsTheNextTwoInFlight() throws {
        let body = Self.pattern(count: 4 << 20)
        let source = FakeHTTP.source(readAheadBytes: 2 << 20, FakeHTTP.ranged(body))
        var read = Data()
        while read.count < 512 << 10 { read += try source.bytes(at: Int64(read.count), count: 256 << 10) }
        let requests = source.requestedRanges.sorted { $0.start < $1.start }
        #expect(requests.map(\.start) == [0, 512 << 10, 1536 << 10])
        #expect(requests.map(\.limit) == [512 << 10, 1 << 20, 2 << 20])
        while read.count < body.count { read += try source.bytes(at: Int64(read.count), count: 256 << 10) }
        #expect(read == body)
    }

    @Test func readersTakeBytesAsTheyArrive() throws {
        let fetch = RangeFetch(start: 100, limit: 200, meter: TransferMeter())
        let response = HTTPURLResponse(
            url: URL(string: "http://fake.test/video.mkv")!, statusCode: 206, httpVersion: nil,
            headerFields: ["Content-Range": "bytes 100-299/1000"]
        )
        #expect(fetch.receive(Data(repeating: 7, count: 50), response: response))
        #expect(fetch.wait(for: 120))
        #expect(fetch.covers(200, reach: 512))
        var buffer = [UInt8](repeating: 0, count: 100)
        #expect(buffer.withUnsafeMutableBytes { fetch.copy(from: 120, into: $0) } == 30)
        fetch.complete(response: response, error: URLError(.networkConnectionLost))
        #expect(!fetch.wait(for: 150))
        #expect(!fetch.covers(150, reach: 512))
    }

    /// A paused reader still sees what the link carried, not the pause.
    @Test func meterCountsOnlyTimeWithARequestInFlight() {
        let now = OSAllocatedUnfairLock(initialState: UInt64(0))
        let meter = TransferMeter(clock: { now.withLock { $0 } })
        meter.began()
        now.withLock { $0 = 1_000_000_000 }
        meter.received(1_000_000)
        meter.ended()
        now.withLock { $0 = 11_000_000_000 }
        meter.began()
        now.withLock { $0 = 12_000_000_000 }
        meter.received(1_000_000)
        meter.ended()
        now.withLock { $0 = 20_000_000_000 }
        #expect(meter.bytesPerSecond() == 1_000_000)
    }

    private static func pattern(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { bytes in
            for i in 0..<count { bytes[i] = UInt8(truncatingIfNeeded: i % 251) }
        }
        return data
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
