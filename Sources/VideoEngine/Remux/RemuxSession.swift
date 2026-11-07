import Foundation
import LoopbackHLS
import os

/// Plays a source AVPlayer cannot open directly (Matroska, for instance) by copying its audio and video
/// into a fragmented MP4 that grows on disk and is served as HLS from 127.0.0.1. No re-encoding.
///
/// `start(at:)` returns the playlist URL for AVPlayer. Each `seek(to:)` begins a new run at that point
/// with its own URL. `stop()` ends the run and deletes its file; it also runs on deinit.
public final class RemuxSession: Sendable {
    /// Forward buffer for the AVPlayerItem: the playlist grows in real time, so a larger buffer only
    /// makes AVPlayer wait for fragments that do not exist yet.
    public static let recommendedForwardBufferDuration: TimeInterval = 15

    /// Every run's events. Finishes after `stop()`.
    public let events: AsyncStream<RemuxEvent>

    private struct Active: Sendable {
        let run: RemuxRun
        let server: LoopbackServer
        let url: URL
    }

    private struct State: Sendable {
        var active: Active?
        var stopped = false
    }

    private let continuation: AsyncStream<RemuxEvent>.Continuation
    private let makeSource: @Sendable () throws -> any ByteRangeSource
    private let options: RemuxOptions
    private let logger: EngineLogger
    private let state = OSAllocatedUnfairLock(initialState: State())

    public convenience init(
        url: URL,
        headers: [String: String] = [:],
        readAheadBytes: Int = 4 << 20,
        options: RemuxOptions = RemuxOptions(),
        logger: EngineLogger = .silent
    ) {
        self.init(
            sourceFactory: { try ByteRangeSources.make(for: url, headers: headers, readAheadBytes: readAheadBytes) },
            options: options,
            logger: logger
        )
    }

    /// - Parameter sourceFactory: called once per run, on the run's thread.
    public init(
        sourceFactory: @escaping @Sendable () throws -> any ByteRangeSource,
        options: RemuxOptions = RemuxOptions(),
        logger: EngineLogger = .silent
    ) {
        (events, continuation) = AsyncStream.makeStream(of: RemuxEvent.self, bufferingPolicy: .bufferingNewest(32))
        self.makeSource = sourceFactory
        self.options = options
        self.logger = logger
    }

    deinit { stop() }

    /// The current run's progress.
    public var progress: RemuxProgress {
        state.withLock { $0.active?.run }?.progress ?? RemuxProgress()
    }

    /// Movie time at which the current run's output timeline starts, once its first packets are read;
    /// also sent as `.timeline(origin:)`. A position `t` on the output timeline is movie time `t + origin`.
    public var timelineOrigin: TimeInterval? {
        state.withLock { $0.active?.run }?.origin
    }

    /// The current run's subtitles, once the source is open: text ones are renditions of the multivariant
    /// playlist that AVPlayer offers by name; picture ones carry an overlay track for the app to draw.
    public var subtitleStreams: [RemuxSubtitle] {
        state.withLock { $0.active?.run }?.subtitles ?? []
    }

    /// Starts the first run and returns its playlist URL; returns the current URL when a run exists.
    /// Throws `CancellationError` after `stop()`.
    public func start(at time: TimeInterval = 0) async throws -> URL {
        try await launch(at: time, replacingCurrent: false)
    }

    /// Replaces the current run with one that starts at the keyframe at or before `time` (movie seconds)
    /// and returns its URL. The new output's timeline starts at that run's origin, so the item is
    /// positioned at `time - origin` to land on `time` exactly.
    public func seek(to time: TimeInterval) async throws -> URL {
        try await launch(at: time, replacingCurrent: true)
    }

    /// The player's position on the current run's timeline; production waits once it is
    /// `paceLeadSeconds` ahead of it.
    public func updatePlayhead(_ seconds: TimeInterval) {
        state.withLock { $0.active?.run }?.setPlayhead(seconds)
    }

    /// Ends the current run, deletes its file and finishes `events`. Idempotent.
    public func stop() {
        let active = state.withLock { state -> Active? in
            state.stopped = true
            defer { state.active = nil }
            return state.active
        }
        if let active { end(active) }
        continuation.finish()
    }

    /// Deletes files an earlier process left behind. Call once at launch, before any session starts.
    public static func sweepStaleFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        prefixes: [String] = [RemuxOptions().tempFilePrefix]
    ) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func launch(at time: TimeInterval, replacingCurrent: Bool) async throws -> URL {
        if !replacingCurrent, let url = try currentURL() { return url }
        let fileURL = options.tempDirectory.appendingPathComponent("\(options.tempFilePrefix)\(UUID().uuidString).mp4")
        let run = RemuxRun(fileURL: fileURL, startTime: max(0, time), openTimeout: options.openTimeout, logger: logger)
        let server = LoopbackServer(routes: [
            LoopbackRoute(path: "/master.m3u8", .playlist({ run.multivariantPlaylist() })),
            LoopbackRoute(path: "/index.m3u8", .playlist({ run.playlist() })),
            LoopbackRoute(path: "/subs/", .generated({ run.subtitleResponse($0) })),
            LoopbackRoute(path: "/media.mp4", .growingFile(
                fileURL, availableBytes: { run.bytesWritten }, isComplete: { run.isComplete }, contentType: "video/mp4"
            )),
        ], queueLabel: "videoengine-remux")
        let base: URL
        do {
            base = try await server.start()
        } catch {
            throw VideoEngineError.serverBindFailed
        }
        let playlist = options.multivariantPlaylist ? "master.m3u8" : "index.m3u8"
        let active = Active(run: run, server: server, url: base.appendingPathComponent(playlist))
        let swap = state.withLock { state -> (accepted: Bool, previous: Active?, current: URL?) in
            if state.stopped { return (false, nil, nil) }
            if !replacingCurrent, let current = state.active { return (false, nil, current.url) }
            defer { state.active = active }
            return (true, state.active, nil)
        }
        guard swap.accepted else {
            server.stop()
            if let url = swap.current { return url }
            throw CancellationError()
        }
        if let previous = swap.previous { end(previous) }
        logger.event("remux-start", [("at", String(format: "%.1f", run.startTime))])

        let continuation = self.continuation
        let remuxer = Remuxer(
            run: run, makeSource: makeSource, options: options, logger: logger,
            contentChanged: { server.contentChanged() },
            emit: { continuation.yield($0) }
        )
        let thread = Thread { remuxer.start() }
        thread.name = "videoengine-remux"
        thread.qualityOfService = .userInitiated
        thread.start()
        return active.url
    }

    private func currentURL() throws -> URL? {
        try state.withLock { state -> URL? in
            if state.stopped { throw CancellationError() }
            return state.active?.url
        }
    }

    /// Stops a run that is being replaced or shut down. Its thread exits at the next packet or read.
    private func end(_ active: Active) {
        active.run.stop()
        if active.run.claimTerminal() { continuation.yield(.stopped(active.run.progress)) }
        active.server.stop()
        try? FileManager.default.removeItem(at: active.run.fileURL)
    }
}
