import Foundation
import Libavcodec
import Libavformat
import Libavutil
import LoopbackHLS
import os

/// One remux run, shared by its worker thread, its loopback routes and the session.
final class RemuxRun: Sendable {
    private struct State: Sendable {
        var progress = RemuxProgress()
        var playhead: TimeInterval = 0
        var sourceSize: Int64?
        var complete = false
        var terminalSent = false
        var source: (any ByteRangeSource)?
        var index: FragmentIndex?
    }

    let fileURL: URL
    /// Source time the output starts at; the output timeline itself starts at 0.
    let startTime: TimeInterval
    let control: RunControl
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(fileURL: URL, startTime: TimeInterval, openTimeout: TimeInterval) {
        self.fileURL = fileURL
        self.startTime = startTime
        self.control = RunControl(timeout: openTimeout)
    }

    var progress: RemuxProgress { state.withLock { $0.progress } }
    var bytesWritten: Int64 { state.withLock { $0.progress.bytesWritten } }
    var isComplete: Bool { state.withLock { $0.complete } }
    var playhead: TimeInterval { state.withLock { $0.playhead } }
    var sourceSize: Int64? { state.withLock { $0.sourceSize } }

    func playlist() -> String? {
        state.withLock { $0.index }?.playlist(mediaName: "media.mp4")
    }

    func setPlayhead(_ seconds: TimeInterval) { state.withLock { $0.playhead = seconds } }

    /// Registers the run's source so `stop()` can cancel a blocked read; cancels it at once if the run
    /// is already stopped.
    func attach(_ source: any ByteRangeSource) {
        state.withLock { $0.source = source }
        if control.isStopped { source.cancel() }
    }

    func opened(sourceSize: Int64?, index: FragmentIndex) {
        state.withLock {
            $0.sourceSize = sourceSize
            $0.index = index
        }
    }

    func recordWrite(total: Int64) { state.withLock { $0.progress.bytesWritten = total } }

    func recordPacket(mediaSeconds: TimeInterval, packets: Int) {
        state.withLock {
            $0.progress.mediaSeconds = mediaSeconds
            $0.progress.packets = packets
        }
    }

    func setPaced(_ paced: Bool) { state.withLock { $0.progress.isPaced = paced } }

    /// Called after the trailer is on disk, so a reader that sees `isComplete` also sees the final size.
    func markComplete() { state.withLock { $0.complete = true } }

    func stop() {
        control.stop()
        state.withLock { $0.source }?.cancel()
    }

    /// True for the first caller only: each run reports exactly one of finished, stopped or failed.
    func claimTerminal() -> Bool {
        state.withLock { s in
            defer { s.terminalSent = true }
            return !s.terminalSent
        }
    }
}

/// Copies the audio and video packets of a source into a fragmented MP4 that is served while it grows.
/// Runs on one dedicated thread, which owns every FFmpeg pointer it creates.
struct Remuxer: Sendable {
    let run: RemuxRun
    let makeSource: @Sendable () throws -> any ByteRangeSource
    let options: RemuxOptions
    let logger: EngineLogger
    let contentChanged: @Sendable () -> Void
    let emit: @Sendable (RemuxEvent) -> Void

    func start() {
        let started = DispatchTime.now()
        let outcome: RemuxEvent
        do {
            try remux()
            outcome = .finished(run.progress)
        } catch {
            if run.control.isStopped || error is CancellationError {
                outcome = .stopped(run.progress)
            } else {
                outcome = .failed((error as? VideoEngineError) ?? .readFailed(code: FF.eio), run.progress)
            }
        }
        // The session deletes the file when it stops a run, but a run stopped before its output opened
        // creates the file afterwards.
        if run.control.isStopped { try? FileManager.default.removeItem(at: run.fileURL) }
        contentChanged()
        let progress = run.progress
        logger.event("remux-end", [
            ("outcome", Self.name(of: outcome)), ("bytes", String(progress.bytesWritten)),
            ("packets", String(progress.packets)), ("media", String(format: "%.1f", progress.mediaSeconds)),
            ("ms", String(milliseconds(since: started))),
        ])
        if run.claimTerminal() { emit(outcome) }
    }

    private func remux() throws {
        let source = try makeSource()
        run.attach(source)
        let input = try DemuxInput(source: source, control: run.control, bufferSize: options.ioBufferBytes)
        defer { input.close() }
        if avformat_find_stream_info(input.context, nil) < 0, run.control.isStopped { throw CancellationError() }
        let info = MediaInfo(format: input.context)
        emit(.opened(info))

        let run = self.run
        let duration = (options.knownDuration ?? info.duration ?? 0) - run.startTime
        let index = FragmentIndex(
            fileURL: run.fileURL,
            available: { [weak run] in run?.bytesWritten ?? 0 },
            isComplete: { [weak run] in run?.isComplete ?? true },
            totalDuration: duration
        )
        run.opened(sourceSize: try? source.length(), index: index)

        let contentChanged = self.contentChanged
        let output = try MuxOutput(formatName: "mp4", fileURL: run.fileURL, bufferSize: options.ioBufferBytes) { total in
            run.recordWrite(total: total)
            contentChanged()
        }
        defer { output.close() }
        let (mapping, videoIndex) = try mapStreams(from: input.context, to: output.context)
        try writeHeader(output)

        if run.startTime > 0, videoIndex >= 0, let stream = input.context.pointee.streams[videoIndex] {
            // A seek may read the container's index at the far end of the file, so it gets the open allowance.
            run.control.extendDeadline(by: options.openTimeout)
            let base = stream.pointee.time_base
            let target = base.num > 0 ? Int64(run.startTime * Double(base.den) / Double(base.num)) : 0
            let sought = av_seek_frame(input.context, Int32(videoIndex), target, FF.seekBackward)
            if sought < 0 {
                if run.control.isStopped { throw CancellationError() }
                logger.event("remux-seek-fail", [("error", FF.errorString(sought)), ("to", String(run.startTime))])
            }
        }

        try copyPackets(from: input, to: output, mapping: mapping, videoIndex: videoIndex)
        let trailer = av_write_trailer(output.context)
        guard trailer >= 0 else { throw VideoEngineError.writeFailed(code: trailer) }
        run.markComplete()
    }

    /// Adds an output stream for each audio and video input stream; cover art and other stream types are
    /// left out. Returns the input-to-output index table and the first video input index (-1 for none).
    private func mapStreams(
        from input: UnsafeMutablePointer<AVFormatContext>, to output: UnsafeMutablePointer<AVFormatContext>
    ) throws -> ([Int], Int) {
        var mapping = [Int](repeating: -1, count: Int(input.pointee.nb_streams))
        var videoIndex = -1
        for i in mapping.indices {
            guard let stream = input.pointee.streams[i], let parameters = stream.pointee.codecpar else { continue }
            let type = parameters.pointee.codec_type
            let isVideo = type == AVMEDIA_TYPE_VIDEO && stream.pointee.disposition & FF.dispositionAttachedPicture == 0
            guard isVideo || type == AVMEDIA_TYPE_AUDIO else { continue }
            guard let outStream = avformat_new_stream(output, nil) else { throw VideoEngineError.outOfMemory }
            let copied = avcodec_parameters_copy(outStream.pointee.codecpar, parameters)
            guard copied >= 0 else { throw VideoEngineError.failure("copy stream parameters", copied) }
            // The source container's tag rarely suits MP4 ("tag not found" for HEVC from Matroska), so the
            // muxer picks one unless the options force an HEVC sample entry.
            let forced = parameters.pointee.codec_id == AV_CODEC_ID_HEVC ? options.hevcTag.fourCC : nil
            outStream.pointee.codecpar.pointee.codec_tag = forced.map(FF.tag) ?? 0
            mapping[i] = Int(outStream.pointee.index)
            if isVideo, videoIndex < 0 { videoIndex = i }
        }
        guard mapping.contains(where: { $0 >= 0 }) else { throw VideoEngineError.noPlayableStreams }
        return (mapping, videoIndex)
    }

    private func writeHeader(_ output: MuxOutput) throws {
        var dictionary: OpaquePointer?
        defer { av_dict_free(&dictionary) }
        // frag_keyframe starts every fragment on a video keyframe, so each one is a decodable HLS segment;
        // empty_moov puts the parameter sets in the init segment that EXT-X-MAP points at.
        let movflags = (["frag_keyframe", "empty_moov", "default_base_moof"] + options.extraMovflags).joined(separator: "+")
        av_dict_set(&dictionary, "movflags", movflags, 0)
        for (key, value) in options.muxerOptions { av_dict_set(&dictionary, key, value, 0) }
        let result = avformat_write_header(output.context, &dictionary)
        guard result >= 0 else {
            logger.event("remux-header-fail", [("error", FF.errorString(result))])
            throw VideoEngineError.headerFailed(code: result, message: FF.errorString(result))
        }
        let initBytes = Int(output.bytesWritten)
        let entry = (try? Data(contentsOf: run.fileURL)).flatMap { InitSegment(data: $0.prefix(initBytes)) }?.videoSampleEntry
        logger.event("remux-header", [("bytes", String(initBytes)), ("entry", entry ?? "none")])
        emit(.headerWritten(initBytes: initBytes, videoSampleEntry: entry))
    }

    private func copyPackets(from input: DemuxInput, to output: MuxOutput, mapping: [Int], videoIndex: Int) throws {
        let packetOwner = try FFPacket()
        defer { withExtendedLifetime(packetOwner) {} }
        let packet = packetOwner.pointer
        let streams = input.context.pointee.streams!
        let outStreams = output.context.pointee.streams!
        var shiftSeconds = -1.0
        var videoSeconds = 0.0
        var packets = 0
        var lastProgress = DispatchTime.now()
        run.control.extendDeadline(by: options.stallTimeout)
        while true {
            try pace(videoSeconds: videoSeconds)
            let result = av_read_frame(input.context, packet)
            if result == FF.averrorEOF, input.readError == nil { return }
            if result < 0 { throw input.readError ?? input.failure(code: result) }
            run.control.extendDeadline(by: options.stallTimeout)

            let inIndex = Int(packet.pointee.stream_index)
            let outIndex = inIndex < mapping.count ? mapping[inIndex] : -1
            guard outIndex >= 0, let inStream = streams[inIndex], let outStream = outStreams[outIndex] else {
                av_packet_unref(packet)
                continue
            }
            let base = inStream.pointee.time_base
            let unit = base.den > 0 ? Double(base.num) / Double(base.den) : 0
            if run.startTime > 0 {
                // Zero-base the output at the first packet after the seek, and drop pre-roll before it.
                let raw = packet.pointee.dts != FF.noPTS ? packet.pointee.dts : packet.pointee.pts
                if shiftSeconds < 0, raw != FF.noPTS { shiftSeconds = Double(raw) * unit }
                let shift = shiftSeconds >= 0 && unit > 0 ? Int64(shiftSeconds / unit) : 0
                if packet.pointee.pts != FF.noPTS { packet.pointee.pts -= shift }
                if packet.pointee.dts != FF.noPTS { packet.pointee.dts -= shift }
                if packet.pointee.dts != FF.noPTS, packet.pointee.dts < 0 {
                    av_packet_unref(packet)
                    continue
                }
            }
            if inIndex == videoIndex, packet.pointee.pts != FF.noPTS { videoSeconds = Double(packet.pointee.pts) * unit }
            av_packet_rescale_ts(packet, base, outStream.pointee.time_base)
            packet.pointee.stream_index = Int32(outIndex)
            packet.pointee.pos = -1
            let written = av_interleaved_write_frame(output.context, packet)
            guard written >= 0 else { throw VideoEngineError.writeFailed(code: written) }
            packets += 1
            run.recordPacket(mediaSeconds: videoSeconds, packets: packets)
            let now = DispatchTime.now()
            if now.uptimeNanoseconds - lastProgress.uptimeNanoseconds >= 500_000_000 {
                lastProgress = now
                emit(.progress(run.progress))
            }
        }
    }

    /// Waits while production is more than `paceLeadSeconds` ahead of the playhead, so a large file is only
    /// downloaded as far as it is watched. Small sources are never paced.
    private func pace(videoSeconds: TimeInterval) throws {
        if run.control.isStopped { throw CancellationError() }
        guard let size = run.sourceSize, size >= options.paceMinSourceBytes,
              videoSeconds - run.playhead > options.paceLeadSeconds else { return }
        run.setPaced(true)
        defer { run.setPaced(false) }
        while videoSeconds - run.playhead > options.paceLeadSeconds {
            if run.control.isStopped { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        run.control.extendDeadline(by: options.stallTimeout)
    }

    private static func name(of event: RemuxEvent) -> String {
        switch event {
        case .finished: "finished"
        case .stopped: "stopped"
        case .failed(let error, _): "failed: \(error)"
        default: "running"
        }
    }
}
