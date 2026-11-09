import Foundation
import os
import Testing
@testable import VideoEngine

/// The HTTP source over a link like Tailscale from a phone: answers start `latency` after the request,
/// each connection carries at most `bytesPerSecond`, and connections drop, the link goes down, or the path
/// dies on command. Each test prints what it measured.
struct LinkTests {
    private static let body = pattern(count: 4 << 20)

    @Test func farLinkRunsMoreRequestsAtOnce() throws {
        for latency in [0.0, 0.08] {
            let server = SlowHTTP.Server(body: Self.body, latency: latency, bytesPerSecond: 2_000_000)
            let source = server.source()
            let start = ContinuousClock.now
            let read = try Self.readAll(source)
            let seconds = Self.seconds(since: start)
            #expect(read == Self.body)
            print(String(
                format: "link: latency %.0f ms, 2 MB/s per connection: %.2f MB/s, measured latency %.0f ms, %ld requests at once",
                latency * 1000, Double(read.count) / seconds / 1e6, (source.latency ?? 0) * 1000, server.peakInFlight
            ))
            if latency > 0 {
                let measured = try #require(source.latency)
                #expect(measured >= 0.08 && measured < 0.3)
                #expect(server.peakInFlight >= 4)
            }
        }
    }

    @Test func droppedConnectionsAreResumed() throws {
        let server = SlowHTTP.Server(body: Self.body, latency: 0.08, bytesPerSecond: 4_000_000) { index in
            index % 3 == 2 ? .drop(after: 100 << 10) : .none
        }
        let source = server.source()
        let start = ContinuousClock.now
        let read = try Self.readAll(source)
        #expect(read == Self.body)
        print(String(format: "link: every third request dropped: %ld dropped, read in %.2f s", server.drops, Self.seconds(since: start)))
    }

    @Test func outageIsRiddenOut() throws {
        let server = SlowHTTP.Server(body: Self.body, latency: 0.08, bytesPerSecond: 4_000_000)
        let source = server.source()
        let sawReconnecting = OSAllocatedUnfairLock(initialState: false)
        var downAt: ContinuousClock.Instant?
        let read = try Self.readAll(source) { count in
            guard count >= 1 << 20, downAt == nil else { return }
            downAt = .now
            server.setDown(true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if source.isReconnecting { sawReconnecting.withLock { $0 = true } }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { server.setDown(false) }
        }
        #expect(read == Self.body)
        #expect(sawReconnecting.withLock { $0 })
        #expect(!source.isReconnecting)
        #expect(source.outageSeconds > 0.3 && source.outageSeconds < 3)
        print(String(format: "link: 0.6 s outage: reads waited %.2f s for the link", source.outageSeconds))
    }

    @Test func networkChangeResumesWithoutWaitingForTheTimeout() throws {
        let server = SlowHTTP.Server(body: Self.body, latency: 0.08, bytesPerSecond: 4_000_000)
        let source = server.source()
        let changedAt = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        var resumedAt: ContinuousClock.Instant?
        var killed = false
        let read = try Self.readAll(source) { count in
            if killed, resumedAt == nil, changedAt.withLock({ $0 }) != nil { resumedAt = .now }
            guard count >= 1 << 20, !killed else { return }
            killed = true
            server.killPath()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                changedAt.withLock { $0 = .now }
                server.changePath()
                source.transport.networkChanged()
            }
        }
        #expect(read == Self.body)
        let changed = try #require(changedAt.withLock { $0 })
        let resumed = try #require(resumedAt)
        let seconds = Self.seconds(resumed - changed)
        print(String(format: "link: path died, network change resumed reads in %.2f s (request timeout 8 s)", seconds))
        #expect(seconds < 2)
    }

    /// Reads the whole body in 256 KiB reads, as FFmpeg does; `progress` sees the total after each read.
    private static func readAll(_ source: HTTPRangeSource, progress: (Int) -> Void = { _ in }) throws -> Data {
        var read = Data()
        while read.count < body.count {
            let chunk = try source.bytes(at: Int64(read.count), count: 256 << 10)
            if chunk.isEmpty { break }
            read += chunk
            progress(read.count)
        }
        return read
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        seconds(ContinuousClock.now - start)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func pattern(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { bytes in
            for i in 0..<count { bytes[i] = UInt8(truncatingIfNeeded: i % 251) }
        }
        return data
    }
}

private final class SlowHTTP: URLProtocol, @unchecked Sendable {
    enum Fault: Sendable {
        case none
        case drop(after: Int)
    }

    /// One fake host: its file, its link and what has happened on it.
    final class Server: Sendable {
        let body: Data
        let latency: TimeInterval
        let bytesPerSecond: Double
        let faults: @Sendable (Int) -> Fault
        let host = "slow-\(UUID().uuidString.lowercased()).test"

        private struct State {
            var requests = 0
            var inFlight = 0
            var peakInFlight = 0
            var drops = 0
            /// Requests fail at once and transfers drop while the link is down.
            var down = false
            /// Transfers on a dead path stop without failing, as a connection on a vanished interface does.
            var deadPaths: Set<Int> = []
            var path = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        init(body: Data, latency: TimeInterval, bytesPerSecond: Double, faults: @escaping @Sendable (Int) -> Fault = { _ in .none }) {
            self.body = body
            self.latency = latency
            self.bytesPerSecond = bytesPerSecond
            self.faults = faults
            SlowHTTP.servers.withLock { $0[host] = self }
        }

        func source() -> HTTPRangeSource {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SlowHTTP.self]
            return HTTPRangeSource(
                url: URL(string: "http://\(host)/video.mkv")!, knownLength: Int64(body.count), readAheadBytes: 1 << 20,
                configuration: configuration
            )
        }

        var peakInFlight: Int { state.withLock { $0.peakInFlight } }
        var drops: Int { state.withLock { $0.drops } }

        func setDown(_ down: Bool) { state.withLock { $0.down = down } }

        /// The current path dies: its transfers and new requests hang.
        func killPath() { state.withLock { _ = $0.deadPaths.insert($0.path) } }

        /// A new path is up; transfers on the old one stay hung.
        func changePath() { state.withLock { $0.path += 1 } }

        /// Registers a request; nil when the link is down.
        func begin() -> (index: Int, path: Int)? {
            state.withLock { s in
                if s.down { return nil }
                s.requests += 1
                s.inFlight += 1
                s.peakInFlight = max(s.peakInFlight, s.inFlight)
                return (s.requests - 1, s.path)
            }
        }

        func end() { state.withLock { $0.inFlight -= 1 } }

        func noteDrop() { state.withLock { $0.drops += 1 } }

        enum Condition { case up, down, dead }

        func condition(of path: Int) -> Condition {
            state.withLock { s in s.deadPaths.contains(path) ? .dead : s.down ? .down : .up }
        }
    }

    static let servers = OSAllocatedUnfairLock(initialState: [String: Server]())

    private let queue = DispatchQueue(label: "slow-http")
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let ended = OSAllocatedUnfairLock(initialState: false)

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return servers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let server = Self.servers.withLock({ $0[host] }),
              let header = request.value(forHTTPHeaderField: "Range"),
              let bounds = header.split(separator: "=").last?.split(separator: "-"), bounds.count == 2,
              let first = Int(bounds[0]), let last = Int(bounds[1]) else {
            ended.withLock { $0 = true }
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let begun = server.begin() else {
            ended.withLock { $0 = true }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let path = begun.path
        let end = min(last, server.body.count - 1) + 1
        let fault = server.faults(begun.index)
        queue.asyncAfter(deadline: .now() + server.latency) { [self] in
            guard !isStopped, server.condition(of: path) == .up else {
                if server.condition(of: path) == .down { fail(server, .networkConnectionLost) }
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(first)-\(end - 1)/\(server.body.count)", "Content-Length": String(end - first)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            send(server, path: path, fault: fault, from: first, to: end, sent: 0)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
        if let server = request.url?.host().flatMap({ host in Self.servers.withLock { $0[host] } }) { finish(server) }
    }

    private var isStopped: Bool { stopped.withLock { $0 } }

    private func send(_ server: Server, path: Int, fault: Fault, from offset: Int, to end: Int, sent: Int) {
        guard !isStopped else { return }
        switch server.condition(of: path) {
        case .dead: return
        case .down: return fail(server, .networkConnectionLost)
        case .up: break
        }
        var count = min(64 << 10, end - offset)
        if case .drop(let after) = fault {
            if sent >= after {
                server.noteDrop()
                return fail(server, .networkConnectionLost)
            }
            count = min(count, after - sent)
        }
        client?.urlProtocol(self, didLoad: server.body.subdata(in: offset..<(offset + count)))
        if offset + count == end {
            client?.urlProtocolDidFinishLoading(self)
            finish(server)
            return
        }
        queue.asyncAfter(deadline: .now() + Double(count) / server.bytesPerSecond) { [self] in
            send(server, path: path, fault: fault, from: offset + count, to: end, sent: sent + count)
        }
    }

    private func fail(_ server: Server, _ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
        finish(server)
    }

    private func finish(_ server: Server) {
        let first = ended.withLock { ended in
            defer { ended = true }
            return !ended
        }
        if first { server.end() }
    }
}
