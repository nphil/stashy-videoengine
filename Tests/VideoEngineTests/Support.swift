import Foundation
import os
@testable import VideoEngine

enum Fixture {
    static func url(_ name: String) throws -> URL {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let url = Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    static func temporaryURL(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("videoengine-test-\(UUID().uuidString)\(suffix)")
    }
}

/// A canned HTTP server behind `URLProtocol`. Each test registers a responder under its own host, so tests
/// can run in parallel.
final class FakeHTTP: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Fails the request with this error instead of answering.
        var failure: URLError.Code?
    }

    typealias Responder = @Sendable (URLRequest) -> Reply

    private static let responders = OSAllocatedUnfairLock(initialState: [String: Responder]())

    /// A source for a fresh host answered by `responder`.
    static func source(retryWindow: TimeInterval = 0, readAheadBytes: Int = 0, _ responder: @escaping Responder) -> HTTPRangeSource {
        let host = "fake-\(UUID().uuidString.lowercased()).test"
        responders.withLock { $0[host] = responder }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHTTP.self]
        // Every stub answers at once; the long timeout only rides out a CI
        // simulator that freezes the test process for seconds at a time.
        return HTTPRangeSource(
            url: URL(string: "http://\(host)/video.mkv")!, readAheadBytes: readAheadBytes, requestTimeout: 60,
            retryWindow: retryWindow, configuration: configuration
        )
    }

    /// Serves `body` honouring `Range`, like a well-behaved file server.
    static func ranged(_ body: Data) -> Responder {
        { request in
            guard let header = request.value(forHTTPHeaderField: "Range"),
                  let range = header.split(separator: "=").last?.split(separator: "-"),
                  range.count == 2, let first = Int(range[0]), let last = Int(range[1]) else {
                return Reply(body: body)
            }
            guard first < body.count else { return Reply(status: 416, headers: ["Content-Range": "bytes */\(body.count)"]) }
            let end = min(last, body.count - 1)
            return Reply(
                status: 206, headers: ["Content-Range": "bytes \(first)-\(end)/\(body.count)"],
                body: body.subdata(in: first..<(end + 1))
            )
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return responders.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let responder = Self.responders.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = responder(request)
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        var headers = reply.headers
        headers["Content-Length"] = String(reply.body.count)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension ByteRangeSource {
    /// One read of up to `count` bytes at `offset`.
    func bytes(at offset: Int64, count: Int) throws -> Data {
        var buffer = Data(count: count)
        let read = try buffer.withUnsafeMutableBytes { try self.read(at: offset, into: $0) }
        return buffer.prefix(read)
    }
}
