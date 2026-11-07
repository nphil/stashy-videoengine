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
        var variant: HLSVariant?
        var origin: TimeInterval?
        /// Start-up timings, reported once the first media playlist is served.
        var stages: [(String, String)] = []
        var startupReported = false
    }

    let fileURL: URL
    /// Source time the run was asked to start at.
    let startTime: TimeInterval
    let control: RunControl
    let started = DispatchTime.now()
    private let logger: EngineLogger
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(fileURL: URL, startTime: TimeInterval, openTimeout: TimeInterval, logger: EngineLogger) {
        self.fileURL = fileURL
        self.startTime = startTime
        self.control = RunControl(timeout: openTimeout)
        self.logger = logger
    }

    var progress: RemuxProgress { state.withLock { $0.progress } }
    var bytesWritten: Int64 { state.withLock { $0.progress.bytesWritten } }
    var isComplete: Bool { state.withLock { $0.complete } }
    var playhead: TimeInterval { state.withLock { $0.playhead } }
    var sourceSize: Int64? { state.withLock { $0.sourceSize } }
    var origin: TimeInterval? { state.withLock { $0.origin } }
    var index: FragmentIndex? { state.withLock { $0.index } }

    /// The media playlist, or nil until the first segment is sealed.
    func playlist() -> String? {
        guard let playlist = index?.playlist() else { return nil }
        reportStartup()
        return playlist
    }

    /// The multivariant playlist, or nil until the init segment is written.
    func multivariantPlaylist() -> String? {
        state.withLock { $0.variant }.map { HLSMultivariantPlaylist(variants: [$0]).render() }
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

    func headerWritten(_ variant: HLSVariant) { state.withLock { $0.variant = variant } }

    func setOrigin(_ origin: TimeInterval) { state.withLock { $0.origin = origin } }

    func recordStage(_ name: String, _ seconds: TimeInterval) {
        let value = String(format: "%.3f", seconds)
        state.withLock { $0.stages.append((name, value)) }
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

    /// Logs the run's start-up timings once, when AVPlayer first gets a playlist with a segment in it.
    private func reportStartup() {
        guard state.withLock({ !$0.startupReported }) else { return }
        let ready = milestone("playlist_ready", since: started)
        let stages = state.withLock { s -> [(String, String)]? in
            guard !s.startupReported else { return nil }
            s.startupReported = true
            return s.stages
        }
        guard let stages else { return }
        logger.measurement(
            "perf-remux",
            [("at", String(format: "%.1f", startTime))] + stages + [("playlist_ready", String(format: "%.3f", ready))]
        )
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

    /// Packets held at the start, at most, while waiting for every stream's first timestamp.
    private static let heldPacketLimit = 48

    func start() {
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
        let index = run.index
        let longest = index?.longestSegment ?? 0
        logger.event("remux-end", [
            ("outcome", Self.name(of: outcome)), ("bytes", String(progress.bytesWritten)),
            ("packets", String(progress.packets)), ("media", String(format: "%.1f", progress.mediaSeconds)),
            ("segments", String(index?.segmentCount ?? 0)), ("longest", String(format: "%.3f", longest)),
            ("ms", String(milliseconds(since: run.started))),
        ])
        // RFC 8216 requires every rounded segment duration to stay within the target.
        if let index, Int(longest.rounded()) > index.targetDuration {
            logger.event("remux-segment-over-target", [
                ("longest", String(format: "%.3f", longest)), ("target", String(index.targetDuration)),
            ])
        }
        if run.claimTerminal() { emit(outcome) }
    }

    private func remux() throws {
        let source = try makeSource()
        run.attach(source)
        let opening = StageTimer("open")
        let input = try DemuxInput(source: source, control: run.control, bufferSize: options.ioBufferBytes)
        defer { input.close() }
        run.recordStage("open", opening.end())
        let probing = StageTimer("find_stream_info")
        if avformat_find_stream_info(input.context, nil) < 0, run.control.isStopped { throw CancellationError() }
        run.recordStage("find_stream_info", probing.end())
        let info = MediaInfo(format: input.context)
        emit(.opened(info))

        let videoIndex = Self.videoStream(of: input.context)
        if run.startTime > 0, videoIndex >= 0 { try seek(input, videoIndex: videoIndex) }

        let index = FragmentIndex(
            mediaName: "media.mp4", targetDuration: Self.targetDuration(of: input.context, videoIndex: videoIndex)
        )
        let sealer = FragmentSealer(index: index)
        run.opened(sourceSize: try? source.length(), index: index)

        let run = self.run
        let contentChanged = self.contentChanged
        let output = try MuxOutput(formatName: "mp4", fileURL: run.fileURL, bufferSize: options.ioBufferBytes) { bytes, total in
            run.recordWrite(total: total)
            sealer.append(bytes)
            contentChanged()
        }
        defer { output.close() }
        let mapping = try mapStreams(from: input.context, to: output.context, videoIndex: videoIndex)
        try writeHeader(output, sealer: sealer, input: input.context, info: info, videoIndex: videoIndex)
        try copyPackets(from: input, to: output, mapping: mapping, videoIndex: videoIndex, sealer: sealer)
        run.markComplete()
        index.finish()
    }

    /// Moves the input to the keyframe at or before the run's start, which may mean reading the container's
    /// index at the far end of the file (Matroska Cues).
    private func seek(_ input: DemuxInput, videoIndex: Int) throws {
        guard let stream = input.context.pointee.streams[videoIndex] else { return }
        run.control.extendDeadline(by: options.openTimeout)
        let seeking = StageTimer("seek")
        // The run's start is movie time; container timestamps may begin above zero (MPEG-TS).
        let containerStart = input.context.pointee.start_time
        let offset = containerStart != FF.noPTS ? Double(containerStart) / Double(FF.timeBase) : 0
        let base = stream.pointee.time_base
        let target = base.num > 0 ? Int64((run.startTime + offset) * Double(base.den) / Double(base.num)) : 0
        let sought = av_seek_frame(input.context, Int32(videoIndex), target, FF.seekBackward)
        run.recordStage("seek", seeking.end())
        if sought < 0 {
            if run.control.isStopped { throw CancellationError() }
            logger.event("remux-seek-fail", [("error", FF.errorString(sought)), ("to", String(run.startTime))])
        }
    }

    /// The first video stream that is not cover art, or -1.
    private static func videoStream(of format: UnsafeMutablePointer<AVFormatContext>) -> Int {
        for i in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams[i], let parameters = stream.pointee.codecpar else { continue }
            if parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
               stream.pointee.disposition & FF.dispositionAttachedPicture == 0 {
                return i
            }
        }
        return -1
    }

    /// Whole seconds no segment exceeds, fixed for the run: the longest keyframe interval in the
    /// container's index, and at least 10 for containers whose index is partial or missing.
    private static func targetDuration(of format: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int) -> Int {
        let minimum = 10
        guard videoIndex >= 0, let stream = format.pointee.streams[videoIndex] else { return minimum }
        var previous: Int64?
        var longest: Int64 = 0
        for i in 0..<avformat_index_get_entries_count(stream) {
            guard let entry = avformat_index_get_entry(stream, i), entry.pointee.flags & FF.indexKeyframe != 0 else { continue }
            if let previous { longest = max(longest, entry.pointee.timestamp - previous) }
            previous = entry.pointee.timestamp
        }
        let seconds = Double(longest) * av_q2d(stream.pointee.time_base)
        return max(minimum, Int(seconds.rounded(.up)))
    }

    /// Adds an output stream for the chosen video stream and for each audio stream. The muxer starts a
    /// fragment at a keyframe of any video track, so a second video stream would cut segments short;
    /// cover art and other stream types are left out too. Returns the input-to-output index table.
    private func mapStreams(
        from input: UnsafeMutablePointer<AVFormatContext>, to output: UnsafeMutablePointer<AVFormatContext>,
        videoIndex: Int
    ) throws -> [Int] {
        var mapping = [Int](repeating: -1, count: Int(input.pointee.nb_streams))
        for i in mapping.indices {
            guard let stream = input.pointee.streams[i], let parameters = stream.pointee.codecpar else { continue }
            guard i == videoIndex || parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            guard let outStream = avformat_new_stream(output, nil) else { throw VideoEngineError.outOfMemory }
            let copied = avcodec_parameters_copy(outStream.pointee.codecpar, parameters)
            guard copied >= 0 else { throw VideoEngineError.failure("copy stream parameters", copied) }
            // The source container's tag rarely suits MP4 ("tag not found" for HEVC from Matroska), so the
            // muxer picks one unless the options force an HEVC sample entry.
            let forced = parameters.pointee.codec_id == AV_CODEC_ID_HEVC ? options.hevcTag.fourCC : nil
            outStream.pointee.codecpar.pointee.codec_tag = forced.map(FF.tag) ?? 0
            mapping[i] = Int(outStream.pointee.index)
        }
        guard mapping.contains(where: { $0 >= 0 }) else { throw VideoEngineError.noPlayableStreams }
        return mapping
    }

    private func writeHeader(
        _ output: MuxOutput, sealer: FragmentSealer, input: UnsafeMutablePointer<AVFormatContext>, info: MediaInfo,
        videoIndex: Int
    ) throws {
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
        // The multivariant playlist is built from the init segment, so it goes to the file now rather than
        // with the first fragment.
        avio_flush(output.context.pointee.pb)
        let initSegment = InitSegment(data: sealer.initSegment)
        let variant = Self.variant(of: initSegment, input: input, videoIndex: videoIndex, info: info)
        run.headerWritten(variant)
        let entry = initSegment?.videoSampleEntry
        logger.event("remux-header", [
            ("bytes", String(sealer.initSegment.count)), ("entry", entry ?? "none"),
            ("codecs", variant.codecs.joined(separator: ",")), ("range", variant.videoRange?.rawValue ?? "none"),
            ("target", String(sealer.index.targetDuration)),
        ])
        emit(.headerWritten(initBytes: sealer.initSegment.count, videoSampleEntry: entry))
    }

    /// The multivariant entry: codecs, resolution and dynamic range from the init segment, frame rate and
    /// bit rate from the source.
    private static func variant(
        of initSegment: InitSegment?, input: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int, info: MediaInfo
    ) -> HLSVariant {
        // The peak is put 20 % above the average; 20 Mbit/s stands in when the source does not say.
        let average = info.bitRate.flatMap { $0 > 0 ? $0 : nil } ?? 20_000_000
        let peak = Int((Double(average) * 1.2).rounded(.up))
        guard let initSegment else { return HLSVariant(uri: "index.m3u8", bandwidth: peak, averageBandwidth: average) }
        var frameRate: Double?
        var transfer: Int?
        if videoIndex >= 0, let stream = input.pointee.streams[videoIndex] {
            let rate = stream.pointee.avg_frame_rate
            if rate.num > 0, rate.den > 0 { frameRate = av_q2d(rate) }
            transfer = stream.pointee.codecpar.map { Int($0.pointee.color_trc.rawValue) }
        }
        return initSegment.variant(
            uri: "index.m3u8", bandwidth: peak, averageBandwidth: average, frameRate: frameRate, transferFallback: transfer
        )
    }

    /// Copies packets until the end of the input, then writes the trailer. The output's timeline starts
    /// at the earliest first timestamp of the copied streams, published as the run's origin.
    private func copyPackets(
        from input: DemuxInput, to output: MuxOutput, mapping: [Int], videoIndex: Int, sealer: FragmentSealer
    ) throws {
        let reading = try FFPacket()
        defer { withExtendedLifetime(reading) {} }
        let packet = reading.pointer
        let streams = input.context.pointee.streams!
        let outStreams = output.context.pointee.streams!
        let copied = Set(mapping.indices.filter { mapping[$0] >= 0 })
        var held: [FFPacket] = []
        var heldStreams = Set<Int>()
        var shifts: [Int64]?
        var videoSeconds = 0.0
        var packets = 0
        var sawPacket = false
        var sawSegment = false
        var lastProgress = DispatchTime.now()

        func noteFirstSegment() {
            guard !sawSegment, sealer.sealedSegments > 0 else { return }
            sawSegment = true
            run.recordStage("first_fragment", milestone("first_fragment", since: run.started))
        }

        func write(_ packet: UnsafeMutablePointer<AVPacket>, shifts: [Int64]) throws {
            let inIndex = Int(packet.pointee.stream_index)
            guard let inStream = streams[inIndex], let outStream = outStreams[mapping[inIndex]] else {
                av_packet_unref(packet)
                return
            }
            let shift = shifts[inIndex]
            if packet.pointee.pts != FF.noPTS { packet.pointee.pts -= shift }
            if packet.pointee.dts != FF.noPTS { packet.pointee.dts -= shift }
            // Pre-roll of a stream whose first packet came after the hold ended.
            if packet.pointee.dts != FF.noPTS, packet.pointee.dts < 0 {
                av_packet_unref(packet)
                return
            }
            let base = inStream.pointee.time_base
            if inIndex == videoIndex, packet.pointee.pts != FF.noPTS { videoSeconds = Double(packet.pointee.pts) * av_q2d(base) }
            av_packet_rescale_ts(packet, base, outStream.pointee.time_base)
            packet.pointee.stream_index = Int32(mapping[inIndex])
            packet.pointee.pos = -1
            let written = av_interleaved_write_frame(output.context, packet)
            guard written >= 0 else { throw VideoEngineError.writeFailed(code: written) }
            packets += 1
            run.recordPacket(mediaSeconds: videoSeconds, packets: packets)
            noteFirstSegment()
            let now = DispatchTime.now()
            if now.uptimeNanoseconds - lastProgress.uptimeNanoseconds >= 500_000_000 {
                lastProgress = now
                emit(.progress(run.progress))
            }
        }

        /// Fixes the origin at the earliest held timestamp and writes the held packets.
        func release() throws {
            var earliest: (ticks: Int64, base: AVRational)?
            for owner in held {
                guard let ticks = Self.timestamp(of: owner.pointer),
                      let stream = streams[Int(owner.pointer.pointee.stream_index)] else { continue }
                let base = stream.pointee.time_base
                if let current = earliest, av_compare_ts(ticks, base, current.ticks, current.base) >= 0 { continue }
                earliest = (ticks, base)
            }
            let origin = earliest ?? (ticks: 0, base: AVRational(num: 1, den: 1))
            // Rounded down, so the packet that sets the origin never lands below zero in another time base.
            let fixed = mapping.indices.map { i -> Int64 in
                guard mapping[i] >= 0, let stream = streams[i] else { return 0 }
                return av_rescale_q_rnd(origin.ticks, origin.base, stream.pointee.time_base, AV_ROUND_DOWN)
            }
            shifts = fixed
            let containerStart = input.context.pointee.start_time
            let movieTime = Double(origin.ticks) * av_q2d(origin.base)
                - (containerStart != FF.noPTS ? Double(containerStart) / Double(FF.timeBase) : 0)
            run.setOrigin(movieTime)
            emit(.timeline(origin: movieTime))
            let released = held
            held.removeAll()
            for owner in released { try write(owner.pointer, shifts: fixed) }
        }

        run.control.extendDeadline(by: options.stallTimeout)
        while true {
            try pace(videoSeconds: videoSeconds)
            let result = av_read_frame(input.context, packet)
            if result == FF.averrorEOF, input.readError == nil { break }
            if result < 0 { throw input.readError ?? input.failure(code: result) }
            run.control.extendDeadline(by: options.stallTimeout)
            if !sawPacket {
                sawPacket = true
                run.recordStage("first_packet", milestone("first_packet", since: run.started))
            }

            let inIndex = Int(packet.pointee.stream_index)
            guard copied.contains(inIndex) else {
                av_packet_unref(packet)
                continue
            }
            if let shifts {
                try write(packet, shifts: shifts)
                continue
            }
            // The first packets wait until every stream has shown its first timestamp, so the output can
            // start at the earliest of them. Shifting by an earlier stream's first packet alone would put
            // another stream's first keyframe below zero, where it is dropped.
            let owner = try FFPacket()
            av_packet_move_ref(owner.pointer, packet)
            if Self.timestamp(of: owner.pointer) != nil { heldStreams.insert(inIndex) }
            held.append(owner)
            if heldStreams == copied || held.count >= Self.heldPacketLimit { try release() }
        }
        if shifts == nil, !held.isEmpty { try release() }
        let trailer = av_write_trailer(output.context)
        guard trailer >= 0 else { throw VideoEngineError.writeFailed(code: trailer) }
        noteFirstSegment()
    }

    private static func timestamp(of packet: UnsafeMutablePointer<AVPacket>) -> Int64? {
        if packet.pointee.dts != FF.noPTS { return packet.pointee.dts }
        return packet.pointee.pts != FF.noPTS ? packet.pointee.pts : nil
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
