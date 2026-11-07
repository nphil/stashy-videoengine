import Foundation
import os

/// Reads an HTTP(S) resource with `Range` requests. Each miss fetches `readAheadBytes` in one request, and
/// the sequential reads that follow are served from that slab.
///
/// A response is used only when it is the requested bytes: 206 with a `Content-Range` that starts at the
/// requested offset, or 200 for a request at offset 0. Error bodies never reach the caller, and a dropped
/// connection is retried and then reported as a failure, never as the end of the file.
public final class HTTPRangeSource: ByteRangeSource {
    public let logName: String
    private let url: URL
    private let headers: [String: String]
    private let readAheadBytes: Int
    private let requestTimeout: TimeInterval
    private let maxAttempts: Int
    private let transport: HTTPTransport
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let wake = DispatchSemaphore(value: 0)

    private struct State {
        var cache: Slab?
        var size: Int64?
        var sizeQueried = false
        var cancelled = false
        var task: URLSessionDataTask?
    }

    /// - Parameters:
    ///   - headers: added to every request; the place for credentials, so they stay out of URLs and logs.
    ///   - readAheadBytes: bytes fetched per request; 0 fetches only what each read asks for.
    ///   - requestTimeout: seconds without data before a request fails and is retried.
    ///   - configuration: a private session configuration, for example one with a test `URLProtocol`. By
    ///     default all sources share one session, so a seek or a probe reuses a warm connection.
    public init(
        url: URL, headers: [String: String] = [:], readAheadBytes: Int = 4 << 20,
        requestTimeout: TimeInterval = 8, maxAttempts: Int = 3, configuration: URLSessionConfiguration? = nil
    ) {
        self.url = url
        self.headers = headers
        self.readAheadBytes = max(0, readAheadBytes)
        self.requestTimeout = requestTimeout
        self.maxAttempts = max(1, maxAttempts)
        self.transport = configuration.map(HTTPTransport.init(configuration:)) ?? .shared
        self.logName = (url.host() ?? "") + "/" + url.lastPathComponent
    }

    public func length() throws -> Int64? {
        try checkCancelled()
        let (size, queried) = state.withLockUnchecked { ($0.size, $0.sizeQueried) }
        if size != nil || queried { return size }
        // The head of the file is what FFmpeg reads first anyway, so learning the size costs no extra request.
        _ = try fetch(at: 0, minimumLength: 1)
        return state.withLockUnchecked { s in
            s.sizeQueried = true
            return s.size
        }
    }

    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try checkCancelled()
        guard buffer.count > 0 else { return 0 }
        if let count = state.withLockUnchecked({ $0.cache })?.copy(from: offset, into: buffer) { return count }
        guard let slab = try fetch(at: offset, minimumLength: buffer.count) else { return 0 }
        return slab.copy(from: offset, into: buffer) ?? 0
    }

    public func cancel() {
        let task = state.withLockUnchecked { s -> URLSessionDataTask? in
            s.cancelled = true
            return s.task
        }
        task?.cancel()
        wake.signal()
    }

    /// The slab starting at `offset`, or nil at the end of the file.
    private func fetch(at offset: Int64, minimumLength: Int) throws -> Slab? {
        let size = state.withLockUnchecked { $0.size }
        if let size, offset >= size { return nil }
        var last = offset + Int64(max(minimumLength, readAheadBytes)) - 1
        if let size { last = min(last, size - 1) }
        var attempt = 1
        while true {
            switch try request(offset...last) {
            case .bytes(let slab, let total):
                state.withLockUnchecked { s in
                    s.cache = slab
                    if let total { s.size = total }
                }
                return slab
            case .endOfFile(let total):
                if let total { state.withLockUnchecked { $0.size = total } }
                return nil
            case .retry where attempt < maxAttempts:
                attempt += 1
                try pause(seconds: 0.5)
            case .retry(let error), .fail(let error):
                throw error
            }
        }
    }

    private func request(_ range: ClosedRange<Int64>) throws -> RangeOutcome {
        try checkCancelled()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let fetch = RangeFetch(start: range.lowerBound, limit: Int(range.upperBound - range.lowerBound + 1))
        let task = transport.start(request, for: fetch)
        let cancelled = state.withLockUnchecked { s -> Bool in
            s.task = task
            return s.cancelled
        }
        if cancelled { task.cancel() }
        fetch.wait()
        state.withLockUnchecked { $0.task = nil }
        try checkCancelled()
        return fetch.outcome()
    }

    /// Waits between attempts; `cancel()` cuts the wait short.
    private func pause(seconds: TimeInterval) throws {
        if wake.wait(timeout: .now() + seconds) == .success { wake.signal() }
        try checkCancelled()
    }

    private func checkCancelled() throws {
        if state.withLockUnchecked({ $0.cancelled }) { throw CancellationError() }
    }
}

/// Contiguous bytes of the resource starting at `start`.
struct Slab: Sendable {
    let start: Int64
    let bytes: Data

    /// Copies from `offset` when the slab holds it, returning the count; nil when it does not.
    func copy(from offset: Int64, into buffer: UnsafeMutableRawBufferPointer) -> Int? {
        guard offset >= start, offset < start + Int64(bytes.count), let target = buffer.baseAddress else { return nil }
        let from = Int(offset - start)
        let count = min(buffer.count, bytes.count - from)
        bytes.withUnsafeBytes { source in target.copyMemory(from: source.baseAddress! + from, byteCount: count) }
        return count
    }
}

enum RangeOutcome: Sendable {
    case bytes(Slab, total: Int64?)
    case endOfFile(total: Int64?)
    /// A failure worth another attempt: no response, a dropped connection, 408, 429 or 5xx.
    case retry(VideoEngineError)
    case fail(VideoEngineError)
}

/// A parsed `Content-Range` header: `bytes first-last/total`, with nil for "*" parts.
struct ContentRange: Equatable, Sendable {
    var first: Int64?
    var last: Int64?
    var total: Int64?

    init(first: Int64?, last: Int64?, total: Int64?) {
        self.first = first
        self.last = last
        self.total = total
    }

    init?(header: String) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        total = Int64(parts[1])
        if parts[0] == "*" { return }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]), first <= last else { return nil }
        self.first = first
        self.last = last
    }
}

/// One range request in flight: the session's delegate queue feeds it and the reading thread waits on it.
final class RangeFetch: Sendable {
    enum Verdict: Sendable {
        case accepted(total: Int64?)
        case rejected(status: Int, total: Int64?)
        case mismatched(String)
    }

    private struct State: Sendable {
        var verdict: Verdict?
        var body = Data()
        var failure: URLError.Code?
        /// Set when the fetch cancelled its own task, so the resulting cancellation error is not a failure.
        var stoppedEarly = false
    }

    let start: Int64
    let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let done = DispatchSemaphore(value: 0)

    init(start: Int64, limit: Int) {
        self.start = start
        self.limit = limit
    }

    /// Adds body bytes; false means the task should be cancelled because the response is unusable or the
    /// requested length has arrived.
    func receive(_ data: Data, response: URLResponse?) -> Bool {
        let verdict = state.withLock { $0.verdict } == nil ? Self.verdict(for: response, start: start) : nil
        return state.withLock { s in
            if s.verdict == nil { s.verdict = verdict ?? .mismatched("not an HTTP response") }
            guard case .accepted = s.verdict else {
                s.stoppedEarly = true
                return false
            }
            if s.body.isEmpty { s.body.reserveCapacity(limit) }
            s.body.append(data.prefix(limit - s.body.count))
            if s.body.count >= limit {
                s.stoppedEarly = true
                return false
            }
            return true
        }
    }

    func complete(response: URLResponse?, error: (any Error)?) {
        let verdict = Self.verdict(for: response, start: start)
        let failure = error.map { ($0 as? URLError)?.code ?? .unknown }
        state.withLock { s in
            if s.verdict == nil { s.verdict = verdict }
            if !s.stoppedEarly { s.failure = failure }
        }
        done.signal()
    }

    func wait() { done.wait() }

    func outcome() -> RangeOutcome {
        let s = state.withLock { $0 }
        switch s.verdict {
        case .accepted(let total):
            // Bytes that arrived before a dropped connection are still the right bytes.
            if !s.body.isEmpty { return .bytes(Slab(start: start, bytes: s.body), total: total) }
            if s.failure == nil, start == 0, total == 0 { return .endOfFile(total: 0) }
            return .retry(s.failure == nil ? .unsupportedSource("empty response at byte \(start)") : .sourceUnreachable(status: nil))
        case .rejected(416, let total):
            if let total, start < total { return .fail(.unsupportedSource("416 for byte \(start) of \(total)")) }
            return .endOfFile(total: total)
        case .rejected(let status, _) where status == 408 || status == 429 || status >= 500:
            return .retry(.sourceUnreachable(status: status))
        case .rejected(let status, _):
            return .fail(.sourceUnreachable(status: status))
        case .mismatched(let reason):
            return .fail(.unsupportedSource(reason))
        case nil:
            return .retry(.sourceUnreachable(status: nil))
        }
    }

    static func verdict(for response: URLResponse?, start: Int64) -> Verdict? {
        guard let http = response as? HTTPURLResponse else { return nil }
        let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.init(header:))
        switch http.statusCode {
        case 206:
            guard let first = range?.first else { return .mismatched("206 without a byte Content-Range") }
            guard first == start else { return .mismatched("server sent bytes from \(first) for a request at \(start)") }
            return .accepted(total: range?.total)
        case 200:
            guard start == 0 else { return .mismatched("server ignored the Range header") }
            return .accepted(total: http.expectedContentLength >= 0 ? http.expectedContentLength : nil)
        default:
            return .rejected(status: http.statusCode, total: range?.total)
        }
    }
}

/// A URLSession whose body data is routed to the `RangeFetch` that started each task. Only a session-level
/// delegate reliably receives body data, and receiving it is what lets an error body or an oversized 200
/// be cut off instead of downloaded.
final class HTTPTransport: Sendable {
    static let shared: HTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return HTTPTransport(configuration: configuration)
    }()

    private let router = TaskRouter()
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        // Readers block on user-initiated threads until these callbacks signal them. A lower-QoS delegate
        // queue would make each wait a priority inversion, which Xcode's Thread Performance Checker reports
        // by stalling the process for seconds.
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.qualityOfService = .userInitiated
        session = URLSession(configuration: configuration, delegate: router, delegateQueue: callbacks)
    }

    deinit { session.invalidateAndCancel() }

    func start(_ request: URLRequest, for fetch: RangeFetch) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        router.register(fetch, for: task.taskIdentifier)
        task.resume()
        return task
    }
}

private final class TaskRouter: NSObject, URLSessionDataDelegate, Sendable {
    private let fetches = OSAllocatedUnfairLock(initialState: [Int: RangeFetch]())

    func register(_ fetch: RangeFetch, for taskID: Int) {
        fetches.withLock { $0[taskID] = fetch }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskID = dataTask.taskIdentifier
        guard let fetch = fetches.withLock({ $0[taskID] }) else { return }
        if !fetch.receive(data, response: dataTask.response) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let taskID = task.taskIdentifier
        guard let fetch = fetches.withLock({ $0.removeValue(forKey: taskID) }) else { return }
        fetch.complete(response: task.response, error: error)
    }
}
