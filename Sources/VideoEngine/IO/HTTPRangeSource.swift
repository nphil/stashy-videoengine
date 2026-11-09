import Foundation
import Network
import os

/// Reads an HTTP(S) resource with `Range` requests.
///
/// A read that no request covers starts a small one, so the header, the index at the end of the file and
/// the resume point each cost one round trip rather than a full read-ahead. Each request that continues a
/// sequential run is twice the size of the one before, up to `readAheadBytes`, and once a request is half
/// read the next two are already in flight, so the link does not idle between them. A read returns as soon
/// as its first bytes arrive, and recently used requests stay cached, so going back to the head of the file
/// after reading its tail costs nothing.
///
/// A response is used only when it is the requested bytes: 206 with a `Content-Range` that starts at the
/// requested offset, or 200 for a request at offset 0. Error bodies never reach the caller, and a dropped
/// connection is retried and then reported as a failure, never as the end of the file.
///
/// A read whose request fails tries again, waiting 0.25 s and then twice as long each time up to 2 s,
/// until `retryWindow` has passed since the first failure. A change of network (Wi-Fi to cellular, a VPN
/// coming up) ends the requests in flight at once, since a connection on the old path can hang without
/// failing until `requestTimeout`.
public final class HTTPRangeSource: ByteRangeSource {
    /// Size of the request that starts a run.
    static let firstRequestBytes = 512 << 10

    /// Requests kept in flight past the one being read. Each request is its own connection, and over a far
    /// link one connection carries less, so more run at once there.
    static func pipelineDepth(latency: TimeInterval?) -> Int {
        guard let latency else { return 2 }
        return latency >= 0.15 ? 4 : latency >= 0.05 ? 3 : 2
    }

    public let logName: String
    private let url: URL
    private let headers: [String: String]
    private let readAheadBytes: Int
    private let cacheBytes: Int
    private let requestTimeout: TimeInterval
    private let retryWindow: TimeInterval
    let transport: HTTPTransport
    private let meter = TransferMeter()
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let wake = DispatchSemaphore(value: 0)

    private struct State {
        /// Requests in flight and finished ones kept for re-reads, least recently used first.
        var entries: [Entry] = []
        var size: Int64?
        var sizeQueried = false
        var cancelled = false
        /// Reads under way.
        var reading = 0
        /// Reads waiting to retry after a failure.
        var reconnecting = 0
        var outageSeconds: TimeInterval = 0
    }

    private struct Entry {
        let fetch: RangeFetch
        /// A read has used it. A jump drops the requests nothing has read, so they stop taking bandwidth.
        var used: Bool
    }

    /// - Parameters:
    ///   - headers: added to every request; the place for credentials, so they stay out of URLs and logs.
    ///   - readAheadBytes: the largest request; 0 fetches only what each read asks for, without read-ahead.
    ///   - requestTimeout: seconds without data before a request fails and is retried.
    ///   - retryWindow: seconds a read keeps retrying after its first failure; 0 reports the first failure.
    ///   - configuration: a private session configuration, for example one with a test `URLProtocol`. By
    ///     default all sources share one session, so a seek or a probe reuses a warm connection.
    ///   - knownLength: the file size when the server already said (Plex's `Part.size`), which saves the
    ///     size lookup and lets FFmpeg seek to the end of the file at once.
    public init(
        url: URL, headers: [String: String] = [:], knownLength: Int64? = nil, readAheadBytes: Int = 4 << 20,
        requestTimeout: TimeInterval = 8, retryWindow: TimeInterval = 30, configuration: URLSessionConfiguration? = nil
    ) {
        self.url = url
        self.headers = headers
        self.readAheadBytes = max(0, readAheadBytes)
        cacheBytes = 6 * max(self.readAheadBytes, Self.firstRequestBytes)
        self.requestTimeout = requestTimeout
        self.retryWindow = max(0, retryWindow)
        self.transport = configuration.map { HTTPTransport(configuration: $0) } ?? .shared
        self.logName = (url.host() ?? "") + "/" + url.lastPathComponent
        if let knownLength {
            state.withLockUnchecked { s in
                s.size = knownLength
                s.sizeQueried = true
            }
        }
    }

    public var bytesPerSecond: Double? { meter.bytesPerSecond() }

    public var latency: TimeInterval? { meter.latency() }

    public var isFetching: Bool { state.withLockUnchecked { $0.reading > 0 } }

    public var isReconnecting: Bool { state.withLockUnchecked { $0.reconnecting > 0 } }

    public var outageSeconds: TimeInterval { state.withLockUnchecked { $0.outageSeconds } }

    public func length() throws -> Int64? {
        try checkCancelled()
        let (size, queried) = state.withLockUnchecked { ($0.size, $0.sizeQueried) }
        if size != nil || queried { return size }
        // The head of the file is what FFmpeg reads first anyway, so learning the size costs no extra request.
        var first: UInt8 = 0
        _ = try withUnsafeMutableBytes(of: &first) { try read(at: 0, into: $0) }
        return state.withLockUnchecked { s in
            s.sizeQueried = true
            return s.size
        }
    }

    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try checkCancelled()
        guard buffer.count > 0 else { return 0 }
        var failedAt: UInt64?
        var failures = 0
        state.withLockUnchecked { $0.reading += 1 }
        defer {
            let outage = failedAt.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1e9 }
            state.withLockUnchecked { s in
                s.reading -= 1
                if let outage {
                    s.reconnecting -= 1
                    s.outageSeconds += outage
                }
            }
        }
        while true {
            guard let found = try fetch(covering: offset, count: buffer.count) else { return 0 }
            let current = found.fetch
            let arrived = current.wait(for: offset)
            try checkCancelled()
            if let total = current.total { state.withLockUnchecked { $0.size = total } }
            if arrived {
                let count = current.copy(from: offset, into: buffer)
                extendPipeline(from: current, readingAt: offset)
                return count
            }
            switch current.outcome() {
            case .endOfFile:
                return 0
            case .fail(let error):
                throw error
            case .retry(let error):
                // A request that stopped short of this read is simply asked again from here; only one made
                // for this read counts as a failure.
                guard found.started else { continue }
                let now = DispatchTime.now().uptimeNanoseconds
                if failedAt == nil {
                    failedAt = now
                    state.withLockUnchecked { $0.reconnecting += 1 }
                }
                if let failedAt, Double(now - failedAt) / 1e9 >= retryWindow { throw error }
                failures += 1
                try pause(seconds: min(2, 0.125 * Double(1 << min(failures, 5))))
            }
        }
    }

    public func cancel() {
        let fetches = state.withLockUnchecked { s -> [RangeFetch] in
            s.cancelled = true
            return s.entries.map(\.fetch)
        }
        for fetch in fetches { fetch.abandon() }
        wake.signal()
    }

    /// The request that has, or is about to receive, the byte at `offset`, starting one when none covers
    /// it; `started` is true for a new one. Nil at the end of the file.
    private func fetch(covering offset: Int64, count: Int) throws -> (fetch: RangeFetch, started: Bool)? {
        var dropped: [RangeFetch] = []
        let found = try state.withLockUnchecked { s -> (fetch: RangeFetch, started: Bool)? in
            if s.cancelled { throw CancellationError() }
            if let size = s.size, offset >= size { return nil }
            // Waiting on a running request beats starting another only when the byte is close behind
            // what has arrived.
            let reach = Int64(max(count, Self.firstRequestBytes))
            if let i = s.entries.firstIndex(where: { $0.fetch.covers(offset, reach: reach) }) {
                var entry = s.entries.remove(at: i)
                entry.used = true
                s.entries.append(entry)
                return (entry.fetch, false)
            }
            for entry in s.entries where !entry.used && !entry.fetch.isFinished { dropped.append(entry.fetch) }
            let length = readAheadBytes > 0 ? max(count, min(Self.firstRequestBytes, readAheadBytes)) : count
            let fetch = RangeFetch(start: offset, limit: Self.clamp(length, at: offset, size: s.size), meter: meter)
            s.entries.append(Entry(fetch: fetch, used: true))
            evict(&s)
            return (fetch, true)
        }
        for fetch in dropped { fetch.abandon() }
        if let found, found.started { begin(found.fetch) }
        return found
    }

    /// Once a read passes the middle of `fetch`, starts the requests that continue it, each twice the size
    /// of the one before up to `readAheadBytes`.
    private func extendPipeline(from fetch: RangeFetch, readingAt offset: Int64) {
        guard readAheadBytes > 0, (offset - fetch.start) * 2 >= Int64(fetch.limit) else { return }
        let depth = Self.pipelineDepth(latency: meter.latency())
        let started = state.withLockUnchecked { s -> [RangeFetch] in
            guard !s.cancelled else { return [] }
            var started: [RangeFetch] = []
            var next = fetch.end
            var length = fetch.limit
            for _ in 0..<depth {
                if let size = s.size, next >= size { break }
                if let ahead = s.entries.first(where: { $0.fetch.start <= next && next < $0.fetch.end })?.fetch {
                    next = ahead.end
                    length = ahead.limit
                    continue
                }
                length = min(length * 2, readAheadBytes)
                let ahead = RangeFetch(start: next, limit: Self.clamp(length, at: next, size: s.size), meter: meter)
                s.entries.append(Entry(fetch: ahead, used: false))
                started.append(ahead)
                next = ahead.end
            }
            evict(&s)
            return started
        }
        for ahead in started { begin(ahead) }
    }

    /// Drops requests that ended without bytes, then the least recently used finished ones until the cache
    /// fits `cacheBytes`. Requests in flight stay; the pipeline already bounds them.
    private func evict(_ s: inout State) {
        s.entries.removeAll { $0.fetch.isFinished && $0.fetch.received == 0 }
        var total = s.entries.reduce(0) { $0 + $1.fetch.limit }
        var i = 0
        while total > cacheBytes, i < s.entries.count - 1 {
            let fetch = s.entries[i].fetch
            if fetch.isFinished {
                total -= fetch.limit
                s.entries.remove(at: i)
            } else {
                i += 1
            }
        }
    }

    private func begin(_ fetch: RangeFetch) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(fetch.start)-\(fetch.start + Int64(fetch.limit) - 1)", forHTTPHeaderField: "Range")
        meter.began()
        fetch.attach(transport.start(request, for: fetch))
    }

    private static func clamp(_ length: Int, at offset: Int64, size: Int64?) -> Int {
        guard let size else { return length }
        return Int(min(Int64(length), size - offset))
    }

    /// Waits between attempts; `cancel()` cuts the wait short.
    private func pause(seconds: TimeInterval) throws {
        if wake.wait(timeout: .now() + seconds) == .success { wake.signal() }
        try checkCancelled()
    }

    private func checkCancelled() throws {
        if state.withLockUnchecked({ $0.cancelled }) { throw CancellationError() }
    }

    /// Start offsets and lengths of the cached and running requests, least recently used first.
    var requestedRanges: [(start: Int64, limit: Int)] {
        state.withLockUnchecked { s in s.entries.map { ($0.fetch.start, $0.fetch.limit) } }
    }
}

/// Download rate over the last few seconds during which a request was in flight, so a reader that pauses
/// still sees what the link carried rather than zero, and the link's latency: the shortest time to the
/// first byte of the last few requests, which leaves out time a request spent queued or the server spent
/// seeking.
final class TransferMeter: Sendable {
    private struct Sample: Sendable {
        var busy: UInt64
        var bytes: Int64
    }

    private struct State: Sendable {
        var active = 0
        var busySince: UInt64 = 0
        var busyBefore: UInt64 = 0
        var bytes: Int64 = 0
        /// Busy time and total bytes, one sample per `step` of busy time over the last `window`.
        var samples: [Sample] = []
        /// Times to the first byte of the most recent requests.
        var firstBytes: [UInt64] = []

        func busy(at now: UInt64) -> UInt64 { busyBefore + (active > 0 ? now - busySince : 0) }
    }

    private static let window: UInt64 = 5_000_000_000
    private static let step: UInt64 = 250_000_000
    private static let latencySamples = 8
    private let clock: @Sendable () -> UInt64
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.clock = clock
    }

    func now() -> UInt64 { clock() }

    func began() {
        let now = clock()
        state.withLock { s in
            if s.active == 0 { s.busySince = now }
            s.active += 1
            if s.samples.isEmpty { s.samples.append(Sample(busy: s.busy(at: now), bytes: s.bytes)) }
        }
    }

    func ended() {
        let now = clock()
        state.withLock { s in
            guard s.active > 0 else { return }
            s.active -= 1
            if s.active == 0 { s.busyBefore += now - s.busySince }
        }
    }

    func received(_ count: Int) {
        guard count > 0 else { return }
        let now = clock()
        state.withLock { s in
            s.bytes += Int64(count)
            let busy = s.busy(at: now)
            guard let last = s.samples.last, busy >= last.busy + Self.step else { return }
            s.samples.append(Sample(busy: busy, bytes: s.bytes))
            if s.samples.count > Int(Self.window / Self.step) + 1 { s.samples.removeFirst() }
        }
    }

    /// Nil until bytes have arrived.
    func bytesPerSecond() -> Double? {
        let now = clock()
        return state.withLock { s -> Double? in
            guard let base = s.samples.first else { return nil }
            let busy = s.busy(at: now)
            guard busy > base.busy, s.bytes > base.bytes else { return nil }
            return Double(s.bytes - base.bytes) / (Double(busy - base.busy) / 1e9)
        }
    }

    /// `requested` is the request's start, from `now()`.
    func firstByte(since requested: UInt64) {
        let elapsed = clock() - requested
        state.withLock { s in
            s.firstBytes.append(elapsed)
            if s.firstBytes.count > Self.latencySamples { s.firstBytes.removeFirst() }
        }
    }

    /// Nil until a request has answered.
    func latency() -> TimeInterval? {
        state.withLock { $0.firstBytes.min() }.map { Double($0) / 1e9 }
    }
}

enum RangeOutcome: Sendable {
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

/// One range request. The session's delegate queue feeds it, and readers take its bytes as they arrive.
final class RangeFetch: Sendable {
    enum Verdict: Sendable {
        case accepted(total: Int64?)
        case rejected(status: Int, total: Int64?)
        case mismatched(String)
    }

    private struct Waiter: Sendable {
        /// Body length that satisfies the reader.
        let needed: Int
        let signal: DispatchSemaphore
    }

    private struct State: Sendable {
        var verdict: Verdict?
        var body = Data()
        var failure: URLError.Code?
        /// Set when the fetch cancelled its own task, so the resulting cancellation error is not a failure.
        var stoppedEarly = false
        var finished = false
        /// Stopped by the source; the bytes that arrived stay readable.
        var abandoned = false
        var waiters: [Waiter] = []
    }

    let start: Int64
    let limit: Int
    private let meter: TransferMeter
    private let requested: UInt64
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let task = OSAllocatedUnfairLock<URLSessionDataTask?>(uncheckedState: nil)

    init(start: Int64, limit: Int, meter: TransferMeter) {
        self.start = start
        self.limit = limit
        self.meter = meter
        requested = meter.now()
    }

    var received: Int { state.withLock { $0.body.count } }

    var isFinished: Bool { state.withLock { $0.finished || $0.abandoned } }

    /// Where the bytes end once the request is done: the requested end while it runs.
    var end: Int64 {
        let (count, done) = state.withLock { ($0.body.count, $0.finished || $0.abandoned) }
        return start + Int64(done ? count : limit)
    }

    /// The resource's size, as the response stated it.
    var total: Int64? {
        switch state.withLock({ $0.verdict }) {
        case .accepted(let total)?, .rejected(416, let total)?: return total
        default: return nil
        }
    }

    /// Whether a read at `offset` should use this request: the byte has arrived, or the request is still
    /// running and the byte is less than `reach` past what has arrived.
    func covers(_ offset: Int64, reach: Int64) -> Bool {
        guard offset >= start, offset < start + Int64(limit) else { return false }
        let (count, running) = state.withLock { ($0.body.count, !$0.finished && !$0.abandoned) }
        let arrived = start + Int64(count)
        return offset < arrived || (running && offset - arrived < reach)
    }

    func attach(_ task: URLSessionDataTask) {
        self.task.withLockUnchecked { $0 = task }
        if state.withLock({ $0.abandoned }) { task.cancel() }
    }

    /// Stops the request and wakes every reader waiting on it.
    func abandon() {
        let waiting = state.withLock { s -> [DispatchSemaphore] in
            s.abandoned = true
            let signals = s.waiters.map(\.signal)
            s.waiters = []
            return signals
        }
        task.withLockUnchecked { $0 }?.cancel()
        for signal in waiting { signal.signal() }
    }

    /// Blocks until the byte at `offset` has arrived or the request has ended; true when it has arrived.
    func wait(for offset: Int64) -> Bool {
        let needed = Int(offset - start) + 1
        let signal = state.withLock { s -> DispatchSemaphore? in
            if s.body.count >= needed || s.finished || s.abandoned { return nil }
            let signal = DispatchSemaphore(value: 0)
            s.waiters.append(Waiter(needed: needed, signal: signal))
            return signal
        }
        signal?.wait()
        return state.withLock { $0.body.count >= needed }
    }

    /// Copies the bytes that have arrived from `offset` on; returns the count.
    func copy(from offset: Int64, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        state.withLockUnchecked { s in
            let from = Int(offset - start)
            guard from >= 0, from < s.body.count, let target = buffer.baseAddress else { return 0 }
            let count = min(buffer.count, s.body.count - from)
            s.body.withUnsafeBytes { source in target.copyMemory(from: source.baseAddress! + from, byteCount: count) }
            return count
        }
    }

    /// Adds body bytes; false means the task should be cancelled because the response is unusable or the
    /// requested length has arrived.
    func receive(_ data: Data, response: URLResponse?) -> Bool {
        let verdict = state.withLock { $0.verdict } == nil ? Self.verdict(for: response, start: start) : nil
        let (more, ready, added, first) = state.withLock { s -> (Bool, [DispatchSemaphore], Int, Bool) in
            if s.verdict == nil { s.verdict = verdict ?? .mismatched("not an HTTP response") }
            guard case .accepted = s.verdict else {
                s.stoppedEarly = true
                return (false, [], 0, false)
            }
            let first = s.body.isEmpty
            if first { s.body.reserveCapacity(limit) }
            let chunk = data.prefix(limit - s.body.count)
            s.body.append(chunk)
            let count = s.body.count
            let ready = s.waiters.filter { $0.needed <= count }.map(\.signal)
            s.waiters.removeAll { $0.needed <= count }
            if count >= limit { s.stoppedEarly = true }
            return (count < limit, ready, chunk.count, first && !chunk.isEmpty)
        }
        if first { meter.firstByte(since: requested) }
        meter.received(added)
        for signal in ready { signal.signal() }
        return more
    }

    func complete(response: URLResponse?, error: (any Error)?) {
        let verdict = Self.verdict(for: response, start: start)
        let failure = error.map { ($0 as? URLError)?.code ?? .unknown }
        let waiting = state.withLock { s -> [DispatchSemaphore] in
            if s.verdict == nil { s.verdict = verdict }
            if !s.stoppedEarly { s.failure = failure }
            s.finished = true
            let signals = s.waiters.map(\.signal)
            s.waiters = []
            return signals
        }
        meter.ended()
        for signal in waiting { signal.signal() }
    }

    /// Why the request ended before a reader's byte, once `wait(for:)` has returned false.
    func outcome() -> RangeOutcome {
        let (verdict, failure, empty) = state.withLock { ($0.verdict, $0.failure, $0.body.isEmpty) }
        switch verdict {
        case .accepted(let total):
            if empty, failure == nil, start == 0, total == 0 { return .endOfFile(total: 0) }
            if empty, failure == nil { return .retry(.unsupportedSource("empty response at byte \(start)")) }
            return .retry(.sourceUnreachable(status: nil))
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
        // A source runs up to five requests at once on a far link (`pipelineDepth`); iOS allows four per
        // host by default.
        configuration.httpMaximumConnectionsPerHost = 6
        return HTTPTransport(configuration: configuration, watchesNetwork: true)
    }()

    private let router = TaskRouter()
    private let session: URLSession
    private let pathMonitor = OSAllocatedUnfairLock<NWPathMonitor?>(uncheckedState: nil)

    init(configuration: URLSessionConfiguration, watchesNetwork: Bool = false) {
        // Readers block on user-initiated threads until these callbacks signal them. A lower-QoS delegate
        // queue would make each wait a priority inversion, which Xcode's Thread Performance Checker reports
        // by stalling the process for seconds.
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.qualityOfService = .userInitiated
        session = URLSession(configuration: configuration, delegate: router, delegateQueue: callbacks)
        if watchesNetwork { watchNetwork() }
    }

    deinit {
        pathMonitor.withLockUnchecked { $0 }?.cancel()
        session.invalidateAndCancel()
    }

    func start(_ request: URLRequest, for fetch: RangeFetch) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        router.register(fetch, for: task.taskIdentifier)
        task.resume()
        return task
    }

    /// A connection on a path that went away can hang without failing until its request times out, so the
    /// requests in flight end now and later ones open new connections.
    func networkChanged() {
        let router = self.router
        session.flush { router.abandonAll() }
    }

    /// Calls `networkChanged()` when the interfaces in use or their order change, which is what a move
    /// between Wi-Fi and cellular or a VPN coming up or down looks like.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        let last = OSAllocatedUnfairLock<String?>(initialState: nil)
        monitor.pathUpdateHandler = { [weak self] path in
            let current = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
            let previous = last.withLock { value -> String? in
                defer { value = current }
                return value
            }
            // The first update describes the path the monitor started on.
            guard let previous, previous != current else { return }
            self?.networkChanged()
        }
        monitor.start(queue: DispatchQueue(label: "videoengine-network-path", qos: .utility))
        pathMonitor.withLockUnchecked { $0 = monitor }
    }
}

private final class TaskRouter: NSObject, URLSessionDataDelegate, Sendable {
    private let fetches = OSAllocatedUnfairLock(initialState: [Int: RangeFetch]())

    func register(_ fetch: RangeFetch, for taskID: Int) {
        fetches.withLock { $0[taskID] = fetch }
    }

    func abandonAll() {
        for fetch in fetches.withLock({ Array($0.values) }) { fetch.abandon() }
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
