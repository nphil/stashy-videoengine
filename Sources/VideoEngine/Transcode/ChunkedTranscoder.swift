import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Re-encodes a local file in keyframe-aligned chunks of about 20 s, each committed as its own MP4, then
/// joins them with the source audio. A run that stopped part-way resumes at the first missing chunk while the
/// plan key is unchanged.
public final class ChunkedTranscoder: MediaTranscoder {
    private let control = RunControl(timeout: .infinity)
    private let workDirectory: URL
    private let planKey: String
    private let logger: EngineLogger

    /// - Parameters:
    ///   - workDirectory: a per-item directory that outlives the process; holds `plan.json` and the chunks.
    ///     Other files in it are left alone.
    ///   - planKey: identifies the settings; a plan made under another key is discarded with its chunks.
    public init(workDirectory: URL, planKey: String, logger: EngineLogger = .silent) {
        self.workDirectory = workDirectory
        self.planKey = planKey
        self.logger = logger
    }

    public func run(input: URL, output: URL, settings: TranscodeSettings, observer: TranscodeObserver) async throws {
        let job = ChunkedTranscodeJob(
            input: input, output: output, settings: settings, observer: observer, control: control, logger: logger,
            workDirectory: workDirectory, planKey: planKey
        )
        let control = control
        try await runBlocking(threadName: "videoengine-transcode", cancel: { control.stop() }) { try job.run() }
    }

    public func cancel() {
        control.stop()
    }
}

/// The chunk plan in `plan.json`. The format is shared with earlier releases, so an interrupted transcode
/// survives an update.
struct ChunkPlan: Codable, Equatable {
    /// Source video timestamps; `end == Int64.max` runs to the end of the file.
    struct Bound: Codable, Equatable {
        var start: Int64
        var end: Int64
    }

    var version: Int
    var settingsKey: String
    var tbNum: Int32
    var tbDen: Int32
    var chunks: [Bound]

    static let chunkSeconds = 20.0

    /// Groups keyframes into chunks of at least `chunkSeconds`, each starting on a keyframe; the last runs to
    /// the end. Without two keyframes or a time base the whole file is one chunk.
    static func make(keyframes: [Int64], tbNum: Int32, tbDen: Int32, key: String) -> ChunkPlan {
        let sorted = keyframes.sorted()
        var bounds: [Bound] = []
        if sorted.count < 2 || tbNum <= 0 || tbDen <= 0 {
            bounds = [Bound(start: sorted.first ?? 0, end: .max)]
        } else {
            let span = Int64(chunkSeconds * Double(tbDen) / Double(tbNum))
            var start = sorted[0]
            for keyframe in sorted.dropFirst() where keyframe - start >= span {
                bounds.append(Bound(start: start, end: keyframe))
                start = keyframe
            }
            bounds.append(Bound(start: start, end: .max))
        }
        return ChunkPlan(version: 1, settingsKey: key, tbNum: tbNum, tbDen: tbDen, chunks: bounds)
    }
}

private struct ChunkedTranscodeJob: Sendable {
    let input: URL
    let output: URL
    let settings: TranscodeSettings
    let observer: TranscodeObserver
    let control: RunControl
    let logger: EngineLogger
    let workDirectory: URL
    let planKey: String

    private var planURL: URL { workDirectory.appendingPathComponent("plan.json") }

    private func chunkURL(_ index: Int) -> URL {
        workDirectory.appendingPathComponent(String(format: "chunk_%04d.mp4", index))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func run() throws {
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let progress = ProgressGate(observer.progress)
        if try copyIfPossible(progress: progress) {
            progress.report(1)
            observer.status("")
            return
        }
        let plan = try loadOrMakePlan()
        let total = plan.chunks.count
        let done = (0..<total).filter { exists(chunkURL($0)) }.count
        observer.log("Resumable: \(total) chunks, \(done) already done")
        logger.event("resume-plan", [("chunks", String(total)), ("done", String(done))])

        var log: (String) -> Void = observer.log
        for index in 0..<total {
            if control.isStopped { throw CancellationError() }
            if exists(chunkURL(index)) {
                // The extra slice in the denominator is the finalize step.
                progress.report(Double(index + 1) / Double(total + 1))
                continue
            }
            try encodeChunk(index, plan: plan, progress: progress, log: log)
            // Only the first chunk encoded in a run logs its decoder set-up.
            log = { _ in }
        }
        if control.isStopped { throw CancellationError() }
        observer.status("Finalizing…")
        try finalize(plan)
        progress.report(1)
        observer.status("")
    }

    /// Copies the streams straight to the output when it would keep the source's codec and size; chunked
    /// re-encoding would only be slower and lossy.
    private func copyIfPossible(progress: ProgressGate) throws -> Bool {
        let demux = try openLocalInput(input, control: control)
        guard let videoIndex = demux.videoStreamIndex, let video = demux.stream(videoIndex),
              let parameters = video.pointee.codecpar, TranscodeRules.canCopy(parameters, settings: settings) else {
            return false
        }
        var indices = [videoIndex]
        if let audio = demux.audioStream, TranscodeRules.copyableAudio.contains(audio.codec) { indices.append(audio.index) }
        let duration = TranscodeRules.duration(of: demux, stream: video)
        try copyStreams(from: demux, indices: indices, to: output.path, control: control) { seconds in
            if duration > 0 { progress.report(seconds / duration) }
        }
        observer.log("Same codec & size → stream copy (no re-encode)")
        return true
    }

    private func loadOrMakePlan() throws -> ChunkPlan {
        if let data = try? Data(contentsOf: planURL), let plan = try? JSONDecoder().decode(ChunkPlan.self, from: data),
           plan.version == 1, plan.settingsKey == planKey, !plan.chunks.isEmpty {
            return plan
        }
        try? FileManager.default.removeItem(at: planURL)
        let files = (try? FileManager.default.contentsOfDirectory(at: workDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("chunk_") { try? FileManager.default.removeItem(at: file) }

        // Keyframe timestamps from one demux-only pass, which decodes nothing and so runs fast.
        let demux = try openLocalInput(input, control: control)
        guard let videoIndex = demux.videoStreamIndex, let video = demux.stream(videoIndex) else {
            throw VideoEngineError.noPlayableStreams
        }
        var keyframes: [Int64] = []
        let packet = try FFPacket()
        while try demux.nextPacket(into: packet.pointer) {
            defer { av_packet_unref(packet.pointer) }
            if control.isStopped { throw CancellationError() }
            let read = packet.pointer.pointee
            guard Int(read.stream_index) == videoIndex, read.flags & FF.packetFlagKey != 0 else { continue }
            let pts = read.pts != FF.noPTS ? read.pts : read.dts
            if pts != FF.noPTS { keyframes.append(pts) }
        }
        let timeBase = video.pointee.time_base
        let plan = ChunkPlan.make(keyframes: keyframes, tbNum: timeBase.num, tbDen: timeBase.den, key: planKey)
        // Written before any chunk, so every committed chunk belongs to a plan on disk.
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
        observer.log("Planned \(plan.chunks.count) chunks from \(keyframes.count) keyframes")
        return plan
    }

    /// Encodes one chunk's video, rebased to start at 0, and commits it with an atomic rename, so a chunk
    /// file that exists is complete.
    private func encodeChunk(_ index: Int, plan: ChunkPlan, progress: ProgressGate, log: @escaping (String) -> Void) throws {
        let bound = plan.chunks[index]
        let temporary = chunkURL(index).appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temporary)

        let demux = try openLocalInput(input, control: control)
        guard let videoIndex = demux.videoStreamIndex, let videoStream = demux.stream(videoIndex) else {
            throw VideoEngineError.noPlayableStreams
        }
        let mp4 = try MP4FileOutput(path: temporary.path)
        let video = try VideoReencoder(stream: videoStream, output: mp4, settings: settings, log: log)
        try mp4.start()
        // The chunk starts on a keyframe, so seeking backwards lands on it exactly.
        av_seek_frame(demux.context, Int32(videoIndex), bound.start, FF.seekBackward)

        let timeBase = videoStream.pointee.time_base
        let encoderTimeBase = video.encoderTimeBase
        let span = bound.end == .max ? 0 : Double(bound.end - bound.start)
        let shares = Double(plan.chunks.count + 1)
        var nextPts: Int64 = 0
        var lastStatus = Date.distantPast
        func decide(_ timestamp: Int64?) -> FrameDecision {
            guard let timestamp else {
                defer { nextPts += 1 }
                return .encode(pts: nextPts)
            }
            // Frames before the start are the decoder's run-up to the keyframe.
            if timestamp < bound.start { return .skip }
            if bound.end != .max, timestamp >= bound.end { return .stop }
            if span > 0 {
                let fraction = min(1, max(0, Double(timestamp - bound.start) / span))
                progress.report((Double(index) + fraction) / shares)
                let now = Date()
                if now.timeIntervalSince(lastStatus) >= 0.5 {
                    lastStatus = now
                    observer.status(String(format: "▸ chunk %d · %d%%", index + 1, Int(fraction * 100)))
                }
            }
            return .encode(pts: av_rescale_q(timestamp - bound.start, timeBase, encoderTimeBase))
        }

        let packet = try FFPacket()
        var reachedEnd = false
        while !reachedEnd {
            if control.isStopped { throw CancellationError() }
            guard try demux.nextPacket(into: packet.pointer) else { break }
            defer { av_packet_unref(packet.pointer) }
            guard Int(packet.pointer.pointee.stream_index) == videoIndex else { continue }
            reachedEnd = try !video.decode(packet.pointer, decide: decide)
        }
        // The last chunk ends at the end of the file: drain the decoder's tail.
        if !reachedEnd { _ = try video.decode(nil, decide: decide) }
        try video.finish()
        try mp4.finish()
        try FileManager.default.moveItem(at: temporary, to: chunkURL(index))
    }

    /// Joins the chunks' video into one timeline and copies the source audio beside it, in one pass. The
    /// audio is never split, so it has no seams at chunk joins.
    private func finalize(_ plan: ChunkPlan) throws {
        let source = try openLocalInput(input, control: control)
        let audio = source.audioStream.flatMap { TranscodeRules.copyableAudio.contains($0.codec) ? $0.index : nil }
        let audioStream = audio.flatMap { source.stream($0) }

        let mp4 = try MP4FileOutput(path: output.path)
        let videoOut: UnsafeMutablePointer<AVStream>
        do {
            let first = try openLocalInput(chunkURL(0), control: control)
            guard let stream = first.stream(0) else { throw VideoEngineError.noPlayableStreams }
            videoOut = try mp4.addCopy(of: stream)
            videoOut.pointee.time_base = stream.pointee.time_base
        }
        let audioOut = try audioStream.map { try mp4.addCopy(of: $0) }
        try mp4.start()
        // Read after the header: the muxer may have changed the time bases.
        let videoTimeBase = videoOut.pointee.time_base
        let common = AVRational(num: 1, den: Int32(FF.timeBase))

        let videoPacket = try FFPacket()
        let audioPacket = try FFPacket()
        var chunkIndex = 0
        var chunk: DemuxInput?
        var chunkBase: Int64 = 0
        var chunkFirstDts = FF.noPTS
        var videoEnd: Int64 = 0

        // The next video packet across chunks; each chunk starts where the previous one ended.
        func nextVideo() throws -> Bool {
            let packet = videoPacket.pointer
            while true {
                if control.isStopped { throw CancellationError() }
                if chunk == nil {
                    guard chunkIndex < plan.chunks.count else { return false }
                    chunk = try openLocalInput(chunkURL(chunkIndex), control: control)
                    chunkBase = videoEnd
                    chunkFirstDts = FF.noPTS
                }
                guard let current = chunk else { return false }
                guard let stream = current.stream(0) else { throw VideoEngineError.noPlayableStreams }
                guard try current.nextPacket(into: packet) else {
                    chunk = nil
                    chunkIndex += 1
                    continue
                }
                let raw = packet.pointee.dts != FF.noPTS ? packet.pointee.dts : packet.pointee.pts
                guard packet.pointee.stream_index == 0, raw != FF.noPTS else {
                    av_packet_unref(packet)
                    continue
                }
                let chunkTimeBase = stream.pointee.time_base
                if chunkFirstDts == FF.noPTS { chunkFirstDts = raw }
                let pts = packet.pointee.pts != FF.noPTS ? packet.pointee.pts : raw
                packet.pointee.dts = chunkBase + av_rescale_q(raw - chunkFirstDts, chunkTimeBase, videoTimeBase)
                packet.pointee.pts = chunkBase + av_rescale_q(pts - chunkFirstDts, chunkTimeBase, videoTimeBase)
                packet.pointee.duration = av_rescale_q(packet.pointee.duration, chunkTimeBase, videoTimeBase)
                packet.pointee.stream_index = videoOut.pointee.index
                packet.pointee.pos = -1
                videoEnd = max(videoEnd, packet.pointee.dts + max(packet.pointee.duration, 1))
                return true
            }
        }

        func nextAudio() throws -> Bool {
            guard let audio, let audioStream, let audioOut else { return false }
            let packet = audioPacket.pointer
            while try source.nextPacket(into: packet) {
                guard Int(packet.pointee.stream_index) == audio else {
                    av_packet_unref(packet)
                    continue
                }
                av_packet_rescale_ts(packet, audioStream.pointee.time_base, audioOut.pointee.time_base)
                packet.pointee.stream_index = audioOut.pointee.index
                packet.pointee.pos = -1
                return true
            }
            return false
        }

        // Interleaved by DTS, so the muxer never buffers a whole track.
        var hasVideo = try nextVideo()
        var hasAudio = try nextAudio()
        while hasVideo || hasAudio {
            if control.isStopped { throw CancellationError() }
            var writeVideo = hasVideo
            if hasVideo, hasAudio, let audioOut {
                writeVideo = av_rescale_q(videoPacket.pointer.pointee.dts, videoTimeBase, common)
                    <= av_rescale_q(audioPacket.pointer.pointee.dts, audioOut.pointee.time_base, common)
            }
            if writeVideo {
                try mp4.write(videoPacket.pointer)
                hasVideo = try nextVideo()
            } else {
                try mp4.write(audioPacket.pointer)
                hasAudio = try nextAudio()
            }
        }
        try mp4.finish()
        observer.log("Finalized \(plan.chunks.count) chunks → \(audioOut != nil ? "video+audio" : "video-only") MP4")
    }
}
