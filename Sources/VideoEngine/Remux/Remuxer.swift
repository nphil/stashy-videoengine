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
        var playerWaiting = false
        var sourceSize: Int64?
        var complete = false
        var terminalSent = false
        var source: (any ByteRangeSource)?
        var index: FragmentIndex?
        var variant: HLSVariant?
        var origin: TimeInterval?
        var subtitles: [RemuxSubtitle] = []
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

    var progress: RemuxProgress {
        let (progress, source) = state.withLock { ($0.progress, $0.source) }
        var current = progress
        current.sourceBytesPerSecond = source?.bytesPerSecond
        current.sourceLatency = source?.latency
        current.isReconnecting = source?.isReconnecting ?? false
        return current
    }
    var bytesWritten: Int64 { state.withLock { $0.progress.bytesWritten } }
    var isComplete: Bool { state.withLock { $0.complete } }
    var playhead: TimeInterval { state.withLock { $0.playhead } }
    var playerWaiting: Bool { state.withLock { $0.playerWaiting } }
    var sourceSize: Int64? { state.withLock { $0.sourceSize } }
    var origin: TimeInterval? { state.withLock { $0.origin } }
    var index: FragmentIndex? { state.withLock { $0.index } }
    var subtitles: [RemuxSubtitle] { state.withLock { $0.subtitles } }

    func setSubtitles(_ subtitles: [RemuxSubtitle]) { state.withLock { $0.subtitles = subtitles } }

    /// The media playlist, or nil until the first segment is sealed.
    func playlist() -> String? {
        guard let playlist = index?.playlist() else { return nil }
        reportStartup()
        return playlist
    }

    /// The multivariant playlist, or nil until the init segment is written. Text subtitles are its
    /// WebVTT renditions.
    func multivariantPlaylist() -> String? {
        let (variant, subtitles) = state.withLock { ($0.variant, $0.subtitles) }
        guard let variant else { return nil }
        let renditions = subtitles.indices.compactMap { i -> HLSSubtitleRendition? in
            let subtitle = subtitles[i]
            guard subtitle.webVTT != nil else { return nil }
            return HLSSubtitleRendition(
                name: subtitle.name, language: subtitle.language, uri: "subs/\(i)/index.m3u8",
                isDefault: subtitle.isDefault, forced: subtitle.isForced,
                characteristics: subtitle.isHearingImpaired
                    ? ["public.accessibility.transcribes-spoken-dialog", "public.accessibility.describes-music-and-sound"] : []
            )
        }
        return HLSMultivariantPlaylist(variants: [variant], subtitles: renditions).render()
    }

    /// Answers `/subs/<n>/index.m3u8` and `/subs/<n>/<slot>.vtt`, or nil while the answer does not exist yet.
    func subtitleResponse(_ path: String) -> (body: Data, contentType: String)? {
        let parts = path.split(separator: "/")
        let subtitles = self.subtitles
        guard parts.count == 3, parts[0] == "subs", let n = Int(parts[1]), subtitles.indices.contains(n),
              let track = subtitles[n].webVTT else { return nil }
        if parts[2] == "index.m3u8" {
            return track.playlist(slotPrefix: "").map { (Data($0.utf8), "application/vnd.apple.mpegurl") }
        }
        guard parts[2].hasSuffix(".vtt"), let slot = Int(parts[2].dropLast(4)), let body = track.slot(slot) else { return nil }
        return (Data(body.utf8), "text/vtt")
    }

    func setPlayhead(_ seconds: TimeInterval) { state.withLock { $0.playhead = seconds } }

    func setPlayerWaiting(_ waiting: Bool) { state.withLock { $0.playerWaiting = waiting } }

    /// The source's measured link, for the pace lead.
    var link: (latency: TimeInterval?, bytesPerSecond: Double?) {
        let source = state.withLock { $0.source }
        return (source?.latency, source?.bytesPerSecond)
    }

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
        // One line per run for the field report: what it produced, how far ahead of the viewer it got and
        // the conditions it ran in.
        logger.measurement("perf-run", [
            ("outcome", Self.name(of: outcome)), ("bytes", String(progress.bytesWritten)),
            ("packets", String(progress.packets)), ("media", String(format: "%.1f", progress.mediaSeconds)),
            ("segments", String(index?.segmentCount ?? 0)), ("longest", String(format: "%.3f", longest)),
            ("ms", String(milliseconds(since: run.started))),
            ("lead_s", String(format: "%.1f", progress.mediaSeconds - run.playhead)),
            ("avail_mb", String(os_proc_available_memory() >> 20)), ("thermal", EngineDiagnostics.thermalState()),
        ])
        // RFC 8216 requires every rounded segment duration to stay within the target.
        if let index, Int(longest.rounded()) > index.targetDuration {
            logger.event("remux-segment-over-target", [
                ("longest", String(format: "%.3f", longest)), ("target", String(index.targetDuration)),
            ])
        }
        if run.claimTerminal() { emit(outcome) }
    }

    /// Runs the remux; when a copied audio stream breaks the muxer before any segment is published, runs
    /// it once more with that audio re-encoded.
    private func remux() throws {
        var copiedAudio = false
        do {
            try remux(forceAudioReencode: false, copiedAudio: &copiedAudio)
        } catch let error as VideoEngineError where copiedAudio && !run.control.isStopped && (run.index?.segmentCount ?? 0) == 0 {
            logger.event("remux-audio-retry", [("error", error.localizedDescription)])
            try remux(forceAudioReencode: true, copiedAudio: &copiedAudio)
        }
    }

    private func remux(forceAudioReencode: Bool, copiedAudio: inout Bool) throws {
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
        let audio = AudioPlan.decide(Self.audioFacts(of: input.context), policy: options.audio, forceReencode: forceAudioReencode)
        copiedAudio = audio?.copiedCodec != nil
        let plan = Self.plan(for: input.context, videoIndex: videoIndex, audio: audio, options: options)
        logger.event("remux-plan", [
            ("tag", plan.videoTag ?? "auto"), ("dolby-vision", "\(plan.dolbyVision)"),
            ("movflags", plan.movflags.joined(separator: "+")),
            ("audio", audio.map { "\($0.streamIndex):\($0.codec):\($0.action)" } ?? "none"),
        ])
        if run.startTime > 0, videoIndex >= 0 { try seek(input, videoIndex: videoIndex) }

        let index = FragmentIndex(
            mediaName: "media.mp4", targetDuration: Self.targetDuration(of: input.context, videoIndex: videoIndex)
        )
        let sealer = FragmentSealer(index: index)
        let subtitles = tapSubtitles(of: input.context, targetDuration: index.targetDuration)
        run.opened(sourceSize: try? source.length(), index: index)

        let run = self.run
        let contentChanged = self.contentChanged
        let output = try MuxOutput(formatName: "mp4", fileURL: run.fileURL, bufferSize: options.ioBufferBytes) { bytes, total in
            run.recordWrite(total: total)
            sealer.append(bytes)
            contentChanged()
        }
        defer { output.close() }
        let (mapping, filters, reencoder) = try mapStreams(
            from: input.context, to: output.context, videoIndex: videoIndex, audio: audio, plan: plan
        )
        var announced = false
        // With delay_moov the init segment arrives with the first fragment rather than the header.
        func announceWhenReady() {
            guard !announced, sealer.hasInitSegment else { return }
            announced = true
            announce(sealer: sealer, input: input.context, info: info, videoIndex: videoIndex)
        }
        try writeHeader(output, plan: plan)
        announceWhenReady()
        try copyPackets(
            from: input, to: output, mapping: mapping, videoIndex: videoIndex, filters: filters, reencoder: reencoder,
            subtitles: subtitles, sealer: sealer, afterWrite: announceWhenReady
        )
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

    /// The first video stream that is not cover art or a Dolby Vision enhancement layer on its own, or -1.
    private static func videoStream(of format: UnsafeMutablePointer<AVFormatContext>) -> Int {
        for i in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams[i], let parameters = stream.pointee.codecpar else { continue }
            if parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
               stream.pointee.disposition & FF.dispositionAttachedPicture == 0,
               dolbyVisionRecord(of: parameters)?.hasBaseLayer != false {
                return i
            }
        }
        return -1
    }

    /// The mux plan for the chosen video stream and the audio the run copies.
    private static func plan(
        for format: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int, audio: AudioPlan?, options: RemuxOptions
    ) -> MuxPlan {
        var videoCodec: String?
        var record: DolbyVisionConfiguration?
        if videoIndex >= 0, let parameters = format.pointee.streams[videoIndex]?.pointee.codecpar {
            videoCodec = String(cString: avcodec_get_name(parameters.pointee.codec_id))
            record = dolbyVisionRecord(of: parameters)
        }
        let audioCodecs = audio?.copiedCodec.map { [$0] } ?? []
        return MuxPlan.decide(videoCodec: videoCodec, dolbyVision: record, audioCodecs: audioCodecs, options: options)
    }

    private static func audioFacts(of format: UnsafeMutablePointer<AVFormatContext>) -> [AudioStreamFacts] {
        (0..<Int(format.pointee.nb_streams)).compactMap { i in
            guard let stream = format.pointee.streams[i], let parameters = stream.pointee.codecpar,
                  parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { return nil }
            let p = parameters.pointee
            var facts = AudioStreamFacts(
                index: i, codec: String(cString: avcodec_get_name(p.codec_id)), channels: Int(p.ch_layout.nb_channels),
                sampleRate: Int(p.sample_rate), bitsPerSample: Int(p.bits_per_raw_sample > 0 ? p.bits_per_raw_sample : p.bits_per_coded_sample),
                isDefault: stream.pointee.disposition & FF.dispositionDefault != 0
            )
            if p.codec_id == AV_CODEC_ID_AAC, let extradata = p.extradata, p.extradata_size > 0 {
                facts.audioSpecificConfig = Array(UnsafeBufferPointer(start: extradata, count: Int(p.extradata_size)))
            }
            return facts
        }
    }

    /// The stream's Dolby Vision configuration record, from Matroska's block addition mapping or an MP4
    /// `dvcC`/`dvvC` box.
    private static func dolbyVisionRecord(of parameters: UnsafeMutablePointer<AVCodecParameters>) -> DolbyVisionConfiguration? {
        guard let side = av_packet_side_data_get(
            parameters.pointee.coded_side_data, parameters.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF
        ), side.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size, let data = side.pointee.data else {
            return nil
        }
        let record = UnsafeRawPointer(data).load(as: AVDOVIDecoderConfigurationRecord.self)
        return DolbyVisionConfiguration(
            profile: Int(record.dv_profile), level: Int(record.dv_level),
            compatibilityID: Int(record.dv_bl_signal_compatibility_id), hasRPU: record.rpu_present_flag != 0,
            hasEnhancementLayer: record.el_present_flag != 0, hasBaseLayer: record.bl_present_flag != 0
        )
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

    /// Adds an output stream for the chosen video stream and the planned audio stream. The muxer starts a
    /// fragment at a keyframe of any video track, so a second video stream would cut segments short;
    /// cover art and other stream types are left out too. Returns the input-to-output index table, the
    /// filters packets pass through by input stream, and the audio re-encoder if the plan needs one.
    private func mapStreams(
        from input: UnsafeMutablePointer<AVFormatContext>, to output: UnsafeMutablePointer<AVFormatContext>,
        videoIndex: Int, audio: AudioPlan?, plan: MuxPlan
    ) throws -> (mapping: [Int], filters: [Int: FFBitstreamFilter], reencoder: AudioReencoder?) {
        var mapping = [Int](repeating: -1, count: Int(input.pointee.nb_streams))
        var filters: [Int: FFBitstreamFilter] = [:]
        var reencoder: AudioReencoder?
        for i in mapping.indices {
            guard let stream = input.pointee.streams[i], let parameters = stream.pointee.codecpar else { continue }
            guard i == videoIndex || i == audio?.streamIndex else { continue }
            guard let outStream = avformat_new_stream(output, nil) else { throw VideoEngineError.outOfMemory }
            mapping[i] = Int(outStream.pointee.index)
            let parametersOut: UnsafeMutablePointer<AVCodecParameters> = outStream.pointee.codecpar
            if i != videoIndex, case .reencode(let channels, let bitRate) = audio?.action {
                reencoder = try AudioReencoder(stream: stream, output: outStream, channels: channels, bitRate: bitRate)
                continue
            }
            var filterName: String?
            if i == videoIndex, plan.dolbyVision == .strip { filterName = "dovi_rpu" }
            if i != videoIndex, audio?.action == .copyCore { filterName = "eac3_core" }
            var source = UnsafePointer(parameters)
            if let filterName {
                let filter = try FFBitstreamFilter(
                    name: filterName, parameters: parameters, timeBase: stream.pointee.time_base,
                    options: filterName == "dovi_rpu" ? ["strip": 1] : [:]
                )
                source = UnsafePointer(filter.pointer.pointee.par_out)
                filters[i] = filter
            }
            let copied = avcodec_parameters_copy(parametersOut, source)
            guard copied >= 0 else { throw VideoEngineError.failure("copy stream parameters", copied) }
            // The source container's tag rarely suits MP4 ("tag not found" for HEVC from Matroska), so the
            // muxer picks one unless the plan names the sample entry.
            parametersOut.pointee.codec_tag = i == videoIndex ? plan.videoTag.map(FF.tag) ?? 0 : 0
            if i == videoIndex { try Self.apply(plan, to: parametersOut) }
            if filterName == "eac3_core" {
                // The core is 5.1; the 7.1 layout would make the muxer describe channels it no longer has.
                av_channel_layout_uninit(&parametersOut.pointee.ch_layout)
                let set = av_channel_layout_from_string(&parametersOut.pointee.ch_layout, "5.1(side)")
                guard set >= 0 else { throw VideoEngineError.failure("set E-AC-3 core layout", set) }
            }
        }
        guard mapping.contains(where: { $0 >= 0 }) else { throw VideoEngineError.noPlayableStreams }
        return (mapping, filters, reencoder)
    }

    /// Writes the plan's Dolby Vision record and colour fields into the output video parameters.
    private static func apply(_ plan: MuxPlan, to parameters: UnsafeMutablePointer<AVCodecParameters>) throws {
        var sides = parameters.pointee.coded_side_data
        var count = parameters.pointee.nb_coded_side_data
        switch plan.dolbyVision {
        case .add(let record):
            guard let side = av_packet_side_data_new(
                &sides, &count, AV_PKT_DATA_DOVI_CONF, MemoryLayout<AVDOVIDecoderConfigurationRecord>.size, 0
            ) else { throw VideoEngineError.outOfMemory }
            var value = AVDOVIDecoderConfigurationRecord()
            value.dv_version_major = 1
            value.dv_profile = UInt8(record.profile)
            value.dv_level = UInt8(record.level)
            value.rpu_present_flag = record.hasRPU ? 1 : 0
            value.el_present_flag = record.hasEnhancementLayer ? 1 : 0
            value.bl_present_flag = record.hasBaseLayer ? 1 : 0
            value.dv_bl_signal_compatibility_id = UInt8(record.compatibilityID)
            UnsafeMutableRawPointer(side.pointee.data!).storeBytes(of: value, as: AVDOVIDecoderConfigurationRecord.self)
        case .drop:
            av_packet_side_data_remove(sides, &count, AV_PKT_DATA_DOVI_CONF)
        case .none, .keep, .strip:
            break
        }
        parameters.pointee.coded_side_data = sides
        parameters.pointee.nb_coded_side_data = count
        if plan.unspecifiedColour {
            parameters.pointee.color_primaries = AVCOL_PRI_UNSPECIFIED
            parameters.pointee.color_trc = AVCOL_TRC_UNSPECIFIED
            parameters.pointee.color_space = AVCOL_SPC_UNSPECIFIED
        }
    }

    private func writeHeader(_ output: MuxOutput, plan: MuxPlan) throws {
        var dictionary: OpaquePointer?
        defer { av_dict_free(&dictionary) }
        av_dict_set(&dictionary, "movflags", plan.movflags.joined(separator: "+"), 0)
        for (key, value) in plan.muxerOptions { av_dict_set(&dictionary, key, value, 0) }
        let result = avformat_write_header(output.context, &dictionary)
        guard result >= 0 else {
            logger.event("remux-header-fail", [("error", FF.errorString(result))])
            throw VideoEngineError.headerFailed(code: result, message: FF.errorString(result))
        }
        // The multivariant playlist is built from the init segment, so it goes to the file now rather than
        // with the first fragment.
        avio_flush(output.context.pointee.pb)
    }

    /// Publishes the multivariant entry once the init segment is complete.
    private func announce(
        sealer: FragmentSealer, input: UnsafeMutablePointer<AVFormatContext>, info: MediaInfo, videoIndex: Int
    ) {
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
        from input: DemuxInput, to output: MuxOutput, mapping: [Int], videoIndex: Int,
        filters: [Int: FFBitstreamFilter], reencoder: AudioReencoder?, subtitles: [Int: SubtitleTap],
        sealer: FragmentSealer, afterWrite: () -> Void
    ) throws {
        let textTracks = run.subtitles.compactMap(\.webVTT)
        let reading = try FFPacket()
        let filtered = try FFPacket()
        defer { withExtendedLifetime((reading, filtered)) {} }
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
        var yielded = false

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
            if inIndex == videoIndex, packet.pointee.pts != FF.noPTS {
                videoSeconds = Double(packet.pointee.pts) * av_q2d(base)
                for track in textTracks { track.readThrough(videoSeconds) }
            }
            av_packet_rescale_ts(packet, base, outStream.pointee.time_base)
            packet.pointee.stream_index = Int32(mapping[inIndex])
            packet.pointee.pos = -1
            let written = av_interleaved_write_frame(output.context, packet)
            guard written >= 0 else { throw VideoEngineError.writeFailed(code: written) }
            packets += 1
            run.recordPacket(mediaSeconds: videoSeconds, packets: packets)
            noteFirstSegment()
            afterWrite()
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
            for track in textTracks { track.setOrigin(movieTime) }
            emit(.timeline(origin: movieTime))
            let released = held
            held.removeAll()
            for owner in released { try write(owner.pointer, shifts: fixed) }
        }

        func deliver(_ packet: UnsafeMutablePointer<AVPacket>) throws {
            if let shifts {
                try write(packet, shifts: shifts)
                return
            }
            // The first packets wait until every stream has shown its first timestamp, so the output can
            // start at the earliest of them. Shifting by an earlier stream's first packet alone would put
            // another stream's first keyframe below zero, where it is dropped.
            let owner = try FFPacket()
            av_packet_move_ref(owner.pointer, packet)
            if Self.timestamp(of: owner.pointer) != nil { heldStreams.insert(Int(owner.pointer.pointee.stream_index)) }
            held.append(owner)
            if heldStreams == copied || held.count >= Self.heldPacketLimit { try release() }
        }

        var gate = PaceGate(lead: options.paceLeadSeconds, headroom: TimeInterval(sealer.index.targetDuration))
        let mediaBytesPerSecond = Self.mediaBytesPerSecond(of: input.context, size: run.sourceSize)
        run.control.extendDeadline(by: options.stallTimeout)
        while true {
            try pace(videoSeconds: videoSeconds, gate: &gate, mediaBytesPerSecond: mediaBytesPerSecond)
            // The viewer waits on the first segments; once one is listed and 8 s are ready, production
            // yields to the interface.
            if !yielded, sawSegment, videoSeconds - run.playhead >= 8 {
                yielded = true
                pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
                logger.event("remux-qos", [("class", "utility"), ("lead_s", String(format: "%.1f", videoSeconds - run.playhead))])
            }
            let result = av_read_frame(input.context, packet)
            if result == FF.averrorEOF, input.readError == nil { break }
            if result < 0 { throw input.readError ?? input.failure(code: result) }
            run.control.extendDeadline(by: options.stallTimeout)
            if !sawPacket {
                sawPacket = true
                run.recordStage("first_packet", milestone("first_packet", since: run.started))
            }

            let inIndex = Int(packet.pointee.stream_index)
            if let tap = subtitles[inIndex] {
                tap.read(packet)
                av_packet_unref(packet)
                continue
            }
            guard copied.contains(inIndex) else {
                av_packet_unref(packet)
                continue
            }
            if let filter = filters[inIndex] {
                try filter.send(packet)
                while try filter.receive(into: filtered.pointer) { try deliver(filtered.pointer) }
            } else if let reencoder, inIndex == reencoder.streamIndex {
                for owner in try reencoder.process(packet) { try deliver(owner.pointer) }
            } else {
                try deliver(packet)
            }
        }
        for filter in filters.values {
            try filter.send(nil)
            while try filter.receive(into: filtered.pointer) { try deliver(filtered.pointer) }
        }
        if let reencoder {
            for owner in try reencoder.process(nil) { try deliver(owner.pointer) }
        }
        if shifts == nil, !held.isEmpty { try release() }
        let trailer = av_write_trailer(output.context)
        guard trailer >= 0 else { throw VideoEngineError.writeFailed(code: trailer) }
        for tap in subtitles.values { tap.finish() }
        for track in textTracks { track.finish(duration: videoSeconds) }
        noteFirstSegment()
        afterWrite()
    }

    /// A source subtitle stream, decoded as it is read into the run's track for it.
    struct SubtitleTap {
        let decoder: SubtitleDecoder
        let stream: RemuxSubtitle

        func read(_ packet: UnsafeMutablePointer<AVPacket>) {
            let decoded = decoder.decode(packet)
            if !decoded.cues.isEmpty { stream.webVTT?.add(contentsOf: decoded.cues) }
            for bitmap in decoded.bitmaps { stream.overlay?.add(bitmap) }
        }

        func finish() {
            for bitmap in decoder.finish() { stream.overlay?.add(bitmap) }
        }
    }

    /// Opens a decoder for each subtitle stream of the source and publishes every subtitle the run offers,
    /// sidecars included. Subtitles are read, never muxed: AVPlayer takes text as WebVTT renditions and has
    /// no picture subtitle format for HLS. A stream FFmpeg cannot decode is left out.
    private func tapSubtitles(of format: UnsafeMutablePointer<AVFormatContext>, targetDuration: Int) -> [Int: SubtitleTap] {
        let containerStart = format.pointee.start_time
        let start = containerStart != FF.noPTS ? Double(containerStart) / Double(FF.timeBase) : 0
        var taps: [Int: SubtitleTap] = [:]
        var offered: [RemuxSubtitle] = []
        var names = Set<String>()
        // NAME must be unique within the rendition group.
        func unique(_ name: String) -> String {
            var candidate = name
            var n = 2
            while !names.insert(candidate).inserted {
                candidate = "\(name) \(n)"
                n += 1
            }
            return candidate
        }
        for i in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams[i],
                  stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let decoder: SubtitleDecoder
            do {
                decoder = try SubtitleDecoder(stream: stream, startTime: start)
            } catch {
                logger.event("subtitle-skipped", [("stream", String(i)), ("error", error.localizedDescription)])
                continue
            }
            let disposition = stream.pointee.disposition
            let language = SubtitleLanguage.tag(MediaInfo.tag("language", in: stream.pointee.metadata))
            let title = MediaInfo.tag("title", in: stream.pointee.metadata)
            var info = RemuxSubtitle(
                streamIndex: i, name: unique(title ?? SubtitleLanguage.displayName(language) ?? "Subtitles \(offered.count + 1)"),
                language: language, isDefault: disposition & FF.dispositionDefault != 0,
                isForced: disposition & FF.dispositionForced != 0,
                isHearingImpaired: disposition & FF.dispositionHearingImpaired != 0
            )
            if decoder.isBitmap {
                info.overlay = SubtitleOverlayTrack()
            } else {
                info.webVTT = SubtitleTrack(targetDuration: targetDuration)
            }
            taps[i] = SubtitleTap(decoder: decoder, stream: info)
            offered.append(info)
        }
        for sidecar in options.sidecarSubtitles {
            let track = SubtitleTrack(targetDuration: targetDuration, holdback: nil)
            track.add(contentsOf: sidecar.cues)
            offered.append(RemuxSubtitle(
                streamIndex: nil, name: unique(sidecar.name), language: SubtitleLanguage.tag(sidecar.language),
                isDefault: sidecar.isDefault, isForced: sidecar.isForced, isHearingImpaired: sidecar.isHearingImpaired,
                webVTT: track
            ))
        }
        run.setSubtitles(offered)
        return taps
    }

    private static func timestamp(of packet: UnsafeMutablePointer<AVPacket>) -> Int64? {
        if packet.pointee.dts != FF.noPTS { return packet.pointee.dts }
        return packet.pointee.pts != FF.noPTS ? packet.pointee.pts : nil
    }

    /// Waits while the gate holds production back, so a large file is only downloaded as far as it is
    /// watched. Small sources are never paced.
    private func pace(videoSeconds: TimeInterval, gate: inout PaceGate, mediaBytesPerSecond: Double?) throws {
        if run.control.isStopped { throw CancellationError() }
        guard let size = run.sourceSize, size >= options.paceMinSourceBytes else { return }
        if videoSeconds - run.playhead > options.paceLeadSeconds {
            let link = run.link
            gate.lead = PaceGate.lead(
                base: options.paceLeadSeconds, latency: link.latency, bytesPerSecond: link.bytesPerSecond,
                mediaBytesPerSecond: mediaBytesPerSecond
            )
        }
        guard !gate.allows(produced: videoSeconds, playhead: run.playhead, playerWaiting: run.playerWaiting) else { return }
        run.setPaced(true)
        defer { run.setPaced(false) }
        repeat {
            if run.control.isStopped { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.2)
        } while !gate.allows(produced: videoSeconds, playhead: run.playhead, playerWaiting: run.playerWaiting)
        run.control.extendDeadline(by: options.stallTimeout)
    }

    /// The source's average rate: the container's bit rate, else its size over its duration.
    private static func mediaBytesPerSecond(of format: UnsafeMutablePointer<AVFormatContext>, size: Int64?) -> Double? {
        if format.pointee.bit_rate > 0 { return Double(format.pointee.bit_rate) / 8 }
        guard let size, format.pointee.duration > 0 else { return nil }
        return Double(size) / (Double(format.pointee.duration) / Double(FF.timeBase))
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
