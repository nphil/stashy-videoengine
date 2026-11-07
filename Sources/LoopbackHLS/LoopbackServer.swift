import Foundation
import Network
import os

public enum LoopbackError: Error, Sendable, Equatable {
    /// No loopback port could be bound.
    case bindFailed
    /// The listener was not ready within 5 s.
    case timedOut
}

/// A loopback-only HTTP/1.1 server (127.0.0.1, OS-assigned port) that serves HLS to AVPlayer from files
/// the app is still producing.
///
/// A playlist lists only byte ranges that are already written, so media requests are normally answered
/// at once with a bounded 206 and a real Content-Length, the request shape AVPlayer handles. Requests at
/// the growing edge wait until the producer calls `contentChanged()`.
public final class LoopbackServer: Sendable {
    private struct State {
        var listener: NWListener?
        var isStopped = false
        var log: [String] = []
    }

    /// Carries a connection through Network's handler closures without relying on its Sendable conformance.
    private struct Connection: @unchecked Sendable {
        let nw: NWConnection
    }

    private let routes: [String: LoopbackRoute.Content]
    /// Routes whose path ends in "/", matched by prefix after the exact routes.
    private let prefixRoutes: [(path: String, content: LoopbackRoute.Content)]
    private let waitTimeout: TimeInterval
    private let queue: DispatchQueue
    private let changes = ChangeSignal()
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// - Parameter waitTimeout: how long a request waits for a playlist or for bytes not yet written.
    public init(routes: [LoopbackRoute], queueLabel: String = "loopback-hls", waitTimeout: TimeInterval = 15) {
        var table: [String: LoopbackRoute.Content] = [:]
        for route in routes where !route.path.hasSuffix("/") { table[route.path] = route.content }
        self.routes = table
        prefixRoutes = routes.filter { $0.path.hasSuffix("/") }.map { ($0.path, $0.content) }
        self.waitTimeout = waitTimeout
        queue = DispatchQueue(label: queueLabel, qos: .userInitiated, attributes: .concurrent)
    }

    /// Starts listening and returns the base URL, `http://127.0.0.1:<port>`, once the listener is ready.
    public func start() async throws -> URL {
        // Loopback only: a wildcard bind would let any LAN peer fetch the media without auth.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LoopbackError.bindFailed
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        state.withLockUnchecked { $0.listener = listener }
        let listenerQueue = DispatchQueue(label: queue.label + ".listener", qos: .userInitiated)
        let failure: LoopbackError? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (LoopbackError?) -> Void = { failure in
                let first = resumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                if first { continuation.resume(returning: failure) }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(nil)
                case .failed, .cancelled: finish(.bindFailed)
                default: break
                }
            }
            listener.start(queue: listenerQueue)
            // Nothing blocks on this, so the limit can outlast the 20 s freezes seen on simulator hosts.
            listenerQueue.asyncAfter(deadline: .now() + 30) { finish(.timedOut) }
        }
        guard failure == nil, let port = listener.port?.rawValue else {
            stop()
            throw failure ?? LoopbackError.bindFailed
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Stops listening and releases waiting requests. Idempotent.
    public func stop() {
        let listener = state.withLockUnchecked { state -> NWListener? in
            state.isStopped = true
            defer { state.listener = nil }
            return state.listener
        }
        listener?.cancel()
        changes.broadcast()
    }

    /// Wakes requests that wait for a playlist or for bytes. Producers call it after each write.
    public func contentChanged() {
        changes.broadcast()
    }

    /// The last 16 requests and their responses, oldest first.
    public func recentRequests() -> [String] {
        state.withLockUnchecked { $0.log }
    }

    // MARK: - Requests

    private func accept(_ nw: NWConnection) {
        nw.start(queue: queue)
        receiveHeader(Connection(nw: nw), buffered: Data())
    }

    /// Reads up to the end of the request header. Request bodies are never needed.
    private func receiveHeader(_ connection: Connection, buffered: Data) {
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.nw.cancel()
                return
            }
            var buffer = buffered
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error == nil, !isComplete, buffer.count < 64 * 1024 {
                self.receiveHeader(connection, buffered: buffer)
            } else {
                connection.nw.cancel()
            }
        }
    }

    private func respond(_ connection: Connection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let method = requestLine.first.map { $0.uppercased() } ?? "GET"
        let target = requestLine.count > 1 ? String(requestLine[1]) : "/"
        let path = String(target.prefix { $0 != "?" })
        let range = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)) }
        let request = Request(connection: connection, path: path, headOnly: method == "HEAD", range: range)

        switch routes[path] ?? prefixRoutes.first(where: { path.hasPrefix($0.path) })?.content {
        case .playlist(let produce)?:
            servePlaylist(request, produce: produce)
        case .growingFile(let url, let availableBytes, let isComplete, let contentType)?:
            serveGrowingFile(request, url: url, availableBytes: availableBytes, isComplete: isComplete,
                             contentType: contentType)
        case .data(let body, let contentType)?:
            serveData(request, body: body, contentType: contentType)
        case .generated(let make)?:
            whenReady({ make(path) }) { generated in
                guard let generated else {
                    self.reply(request, status: 503, note: "not ready")
                    return
                }
                self.serveData(request, body: generated.body, contentType: generated.contentType)
            }
        case nil:
            reply(request, status: 404, note: "")
        }
    }

    private struct Request {
        let connection: Connection
        let path: String
        let headOnly: Bool
        /// The `Range` header value, if any.
        let range: String?
    }

    private func servePlaylist(_ request: Request, produce: @escaping @Sendable () -> String?) {
        whenReady(produce) { text in
            guard let text else {
                self.reply(request, status: 503, note: "not ready")
                return
            }
            self.reply(request, status: 200, headers: [("Content-Type", "application/vnd.apple.mpegurl"),
                                                       ("Cache-Control", "no-cache")],
                       body: Data(text.utf8))
        }
    }

    private func serveGrowingFile(_ request: Request, url: URL, availableBytes: @escaping @Sendable () -> Int64,
                                  isComplete: @escaping @Sendable () -> Bool, contentType: String) {
        var parsed = ByteRangeRequest.bounded(start: 0, end: nil)
        if let value = request.range {
            guard let range = ByteRangeRequest(header: value) else {
                reply(request, status: 416, note: "bad range")
                return
            }
            parsed = range
        }
        let wanted = parsed
        // The playlist lists only written ranges, so this normally answers at once; it covers the race at
        // the growing edge.
        whenReady({ () -> Bool? in
            if isComplete() { return true }
            switch wanted {
            case .bounded(let start, let end): return availableBytes() > (end ?? start) ? true : nil
            case .suffix: return nil
            }
        }) { _ in
            // Completion first: a producer records its final size before it reports completion.
            let complete = isComplete()
            let available = availableBytes()
            guard let range = wanted.resolve(available: available, complete: complete) else {
                self.reply(request, status: 416,
                           headers: complete ? [("Content-Range", "bytes */\(available)")] : [],
                           note: "available \(available)")
                return
            }
            guard let data = Self.read(url, range), !data.isEmpty else {
                self.reply(request, status: 500, note: "read \(range.lowerBound)-\(range.upperBound)")
                return
            }
            let total = complete ? "\(available)" : "*"
            let last = range.lowerBound + Int64(data.count) - 1
            self.reply(request, status: 206,
                       headers: [("Content-Type", contentType), ("Accept-Ranges", "bytes"),
                                 ("Content-Range", "bytes \(range.lowerBound)-\(last)/\(total)")],
                       body: data)
        }
    }

    private func serveData(_ request: Request, body: Data, contentType: String) {
        guard let value = request.range else {
            reply(request, status: 200, headers: [("Content-Type", contentType)], body: body)
            return
        }
        let total = Int64(body.count)
        guard let range = ByteRangeRequest(header: value)?.resolve(available: total, complete: true) else {
            reply(request, status: 416, headers: [("Content-Range", "bytes */\(total)")], note: "")
            return
        }
        let slice = body.subdata(in: Int(range.lowerBound)..<Int(range.upperBound) + 1)
        reply(request, status: 206,
              headers: [("Content-Type", contentType), ("Accept-Ranges", "bytes"),
                        ("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(total)")],
              body: slice)
    }

    // MARK: - Helpers

    /// Calls `done` with the probe's value once it has one, re-checking each time a producer reports new
    /// content and at least every 100 ms; with nil once the server stops or `waitTimeout` passes. No thread
    /// blocks meanwhile: a server thread blocked on a lower-QoS producer is a priority inversion, which
    /// Xcode's Thread Performance Checker reports by stalling the process for seconds.
    private func whenReady<T: Sendable>(
        _ probe: @escaping @Sendable () -> T?, deadline: DispatchTime? = nil, _ done: @escaping @Sendable (T?) -> Void
    ) {
        let deadline = deadline ?? DispatchTime.now() + waitTimeout
        let recheck: @Sendable () -> Void = { [queue] in
            queue.async { self.whenReady(probe, deadline: deadline, done) }
        }
        let id = changes.register(recheck)
        if let value = probe() {
            // When a broadcast already took the registration, its re-check answers instead.
            if changes.withdraw(id) { done(value) }
            return
        }
        if state.withLockUnchecked({ $0.isStopped }) || DispatchTime.now() >= deadline {
            if changes.withdraw(id) { done(nil) }
            return
        }
        queue.asyncAfter(deadline: min(deadline, .now() + .milliseconds(100))) { [changes] in
            if changes.withdraw(id) { recheck() }
        }
    }

    private func reply(_ request: Request, status: Int, headers: [(String, String)] = [],
                       body: Data = Data(), note: String? = nil) {
        var line = request.path
        if let range = request.range { line += " \(range.trimmingCharacters(in: .whitespaces))" }
        line += " →\(status) \(body.count)B"
        if let note, !note.isEmpty { line += " \(note)" }
        record(line)

        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var message = Data(head.utf8)
        if !request.headOnly { message.append(body) }
        let connection = request.connection
        // One complete final message, so Network flushes all of it before the cancel; cancelling after a
        // plain send truncates a large body.
        connection.nw.send(content: message, contentContext: .finalMessage, isComplete: true,
                           completion: .contentProcessed { _ in connection.nw.cancel() })
    }

    private func record(_ line: String) {
        state.withLockUnchecked { state in
            state.log.append(line)
            if state.log.count > 16 { state.log.removeFirst(state.log.count - 16) }
        }
    }

    private static func read(_ url: URL, _ range: ClosedRange<Int64>) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: Int(range.upperBound - range.lowerBound + 1))
        } catch {
            return nil
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 404: "Not Found"
        case 416: "Range Not Satisfiable"
        case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
    }
}

/// The first range of a `Range: bytes=…` header.
enum ByteRangeRequest: Equatable {
    /// `bytes=a-b` (inclusive) or `bytes=a-`.
    case bounded(start: Int64, end: Int64?)
    /// `bytes=-n`: the last n bytes.
    case suffix(length: Int64)

    init?(header: String) {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let first = value.dropFirst("bytes=".count).split(separator: ",").first ?? ""
        let bounds = first.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces))
        let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces))
        switch (start, end) {
        case (let start?, let end):
            guard start >= 0, (end ?? start) >= start else { return nil }
            self = .bounded(start: start, end: end)
        case (nil, let length?):
            guard length > 0 else { return nil }
            self = .suffix(length: length)
        case (nil, nil):
            return nil
        }
    }

    /// The bytes to send from a resource whose first `available` bytes exist, or nil for 416.
    func resolve(available: Int64, complete: Bool) -> ClosedRange<Int64>? {
        switch self {
        case .bounded(let start, let end):
            guard start < available else { return nil }
            return start...min(end ?? available - 1, available - 1)
        case .suffix(let length):
            guard complete, available > 0 else { return nil }
            return max(0, available - length)...(available - 1)
        }
    }
}
