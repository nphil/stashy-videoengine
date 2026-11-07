import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Re-encodes a local file into an MP4 in one pass: VideoToolbox decode and encode, audio copied. When the
/// output would keep the source's codec and size it copies the streams instead, losslessly and in seconds.
public final class FileTranscoder: MediaTranscoder {
    private let control = RunControl(timeout: .infinity)
    private let logger: EngineLogger

    public init(logger: EngineLogger = .silent) {
        self.logger = logger
    }

    public func run(input: URL, output: URL, settings: TranscodeSettings, observer: TranscodeObserver) async throws {
        let job = FileTranscodeJob(input: input, output: output, settings: settings, observer: observer, control: control, logger: logger)
        let control = control
        try await runBlocking(threadName: "videoengine-transcode", cancel: { control.stop() }) { try job.run() }
    }

    public func cancel() {
        control.stop()
    }
}

private struct FileTranscodeJob: Sendable {
    let input: URL
    let output: URL
    let settings: TranscodeSettings
    let observer: TranscodeObserver
    let control: RunControl
    let logger: EngineLogger

    func run() throws {
        let demux = try openLocalInput(input, control: control)
        guard let videoIndex = demux.videoStreamIndex, let video = demux.stream(videoIndex), let parameters = video.pointee.codecpar else {
            throw VideoEngineError.noPlayableStreams
        }
        let codecName = FF.string(avcodec_get_name(parameters.pointee.codec_id)) ?? "unknown"
        let audio = demux.audioStream
        if let audio, !TranscodeRules.copyableAudio.contains(audio.codec) {
            throw VideoEngineError.audioNotCopyable(codec: audio.codec)
        }
        observer.log("Input: \(codecName) \(parameters.pointee.width)×\(parameters.pointee.height)")
        observer.log(audio.map { "Audio: \($0.codec) (stream copy)" } ?? "Audio: none")
        let duration = TranscodeRules.duration(of: demux, stream: video)
        let progress = ProgressGate(observer.progress)

        if TranscodeRules.canCopy(parameters, settings: settings) {
            observer.log("Same codec & size → stream copy (no re-encode)")
            try copyStreams(from: demux, indices: [videoIndex] + (audio.map { [$0.index] } ?? []), to: output.path, control: control) { seconds in
                if duration > 0 { progress.report(seconds / duration) }
            }
            progress.report(1)
            observer.log("Done: stream copy complete")
            logger.event("transcode-end", [("mode", "copy"), ("seconds", String(format: "%.0f", duration))])
            return
        }
        try reencode(demux, videoIndex: videoIndex, audioIndex: audio?.index, duration: duration > 0 ? duration : 0.1, progress: progress)
    }

    private func reencode(_ demux: DemuxInput, videoIndex: Int, audioIndex: Int?, duration: Double, progress: ProgressGate) throws {
        let mp4 = try MP4FileOutput(path: output.path)
        let videoStream = demux.stream(videoIndex)!
        let video = try VideoReencoder(stream: videoStream, output: mp4, settings: settings, log: observer.log)
        let audioStream = audioIndex.flatMap { demux.stream($0) }
        let audioOut = try audioStream.map { try mp4.addCopy(of: $0) }
        try mp4.start()
        observer.log("Encoder: \(settings.codec.encoderName) → \(video.size.width)×\(video.size.height) @ ~\(video.bitrate / 1000) kbps")
        observer.log(String(format: "Duration: %.0fs%@", duration, settings.maxLongEdge != nil ? " · scaling on" : ""))

        let streamTimeBase = videoStream.pointee.time_base
        let encoderTimeBase = video.encoderTimeBase
        let started = Date()
        var frames = 0
        var nextPts: Int64 = 0
        var lastStatus = Date.distantPast
        // One status line, replaced in place, at most twice a second.
        func showStatus() {
            let now = Date()
            guard now.timeIntervalSince(lastStatus) >= 0.5 else { return }
            lastStatus = now
            let elapsed = now.timeIntervalSince(started)
            let done = progress.lastReported
            let fps = elapsed > 0 ? Double(frames) / elapsed : 0
            let speed = elapsed > 0 ? done * duration / elapsed : 0
            let eta = done > 0.01 ? elapsed * (1 - done) / done : 0
            let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.doubleValue ?? 0
            observer.status(String(
                format: "▸ %.0f fps · %d%% · %.1f× realtime · ETA %@ · %.0f MB · %d frames",
                fps, Int(done * 100), speed, clockText(eta), bytes / 1_000_000, frames
            ))
        }
        func decide(_ timestamp: Int64?) -> FrameDecision {
            frames += 1
            defer { showStatus() }
            guard let timestamp else {
                // No timestamp: keep the frames in decode order.
                defer { nextPts += 1 }
                return .encode(pts: nextPts)
            }
            progress.report(Double(timestamp) * av_q2d(streamTimeBase) / duration)
            return .encode(pts: av_rescale_q(timestamp, streamTimeBase, encoderTimeBase))
        }

        let packet = try FFPacket()
        while true {
            if control.isStopped { throw CancellationError() }
            guard try demux.nextPacket(into: packet.pointer) else { break }
            defer { av_packet_unref(packet.pointer) }
            let index = Int(packet.pointer.pointee.stream_index)
            if index == videoIndex {
                _ = try video.decode(packet.pointer, decide: decide)
            } else if index == audioIndex, let audioStream, let audioOut {
                av_packet_rescale_ts(packet.pointer, audioStream.pointee.time_base, audioOut.pointee.time_base)
                packet.pointer.pointee.stream_index = audioOut.pointee.index
                packet.pointer.pointee.pos = -1
                try mp4.write(packet.pointer)
            }
        }
        _ = try video.decode(nil, decide: decide)
        try video.finish()
        progress.report(1)
        try mp4.finish()

        let elapsed = Date().timeIntervalSince(started)
        observer.status("")
        observer.log(String(
            format: "Done: %d frames in %.1fs (avg %.0f fps, %.1f× realtime)",
            frames, elapsed, elapsed > 0 ? Double(frames) / elapsed : 0, elapsed > 0 ? duration / elapsed : 0
        ))
        logger.event("transcode-end", [
            ("mode", "encode"), ("frames", String(frames)), ("seconds", String(format: "%.1f", elapsed)),
            ("kbps", String(video.bitrate / 1000)),
        ])
    }
}
