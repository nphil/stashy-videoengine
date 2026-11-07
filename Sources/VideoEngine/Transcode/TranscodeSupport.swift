import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Runs blocking FFmpeg work on its own thread, never on the cooperative pool, and turns Task cancellation
/// into `cancel`.
func runBlocking(threadName: String, cancel: @escaping @Sendable () -> Void, _ body: @escaping @Sendable () throws -> Void) async throws {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let thread = Thread { continuation.resume(with: Result { try body() }) }
            thread.name = threadName
            thread.start()
        }
    } onCancel: {
        cancel()
    }
}

/// Opens a local file through the engine's own IO, so cancellation and read errors behave as for streams.
func openLocalInput(_ url: URL, control: RunControl) throws -> DemuxInput {
    if control.isStopped { throw CancellationError() }
    let input = try DemuxInput(source: FileRangeSource(fileURL: url), control: control, bufferSize: 256 << 10)
    let found = avformat_find_stream_info(input.context, nil)
    if found < 0 {
        if control.isStopped { throw CancellationError() }
        throw VideoEngineError.openFailed(code: found, message: FF.errorString(found))
    }
    return input
}

extension DemuxInput {
    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>? {
        guard index >= 0, index < Int(context.pointee.nb_streams) else { return nil }
        return context.pointee.streams[index]
    }

    /// The main video stream, never cover art.
    var videoStreamIndex: Int? {
        let best = Int(av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
        if let stream = stream(best), stream.pointee.disposition & FF.dispositionAttachedPicture == 0 { return best }
        return (0..<Int(context.pointee.nb_streams)).first { index in
            guard let stream = stream(index), let parameters = stream.pointee.codecpar else { return false }
            return parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                && stream.pointee.disposition & FF.dispositionAttachedPicture == 0
        }
    }

    /// The main audio stream and its codec name.
    var audioStream: (index: Int, codec: String)? {
        let best = Int(av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0))
        guard let stream = stream(best), let parameters = stream.pointee.codecpar else { return nil }
        return (best, FF.string(avcodec_get_name(parameters.pointee.codec_id)) ?? "unknown")
    }

    /// Reads the next packet; false at the real end of the file. Named apart from the AVIO read trampoline,
    /// which a member of the same name would shadow inside `DemuxInput`.
    func nextPacket(into packet: UnsafeMutablePointer<AVPacket>) throws -> Bool {
        let result = av_read_frame(context, packet)
        if result == FF.averrorEOF, readError == nil { return false }
        if result < 0 { throw readError ?? failure(code: result) }
        return true
    }
}

enum TranscodeRules {
    /// Audio an iPhone decodes inside an MP4, so a transcode copies it untouched.
    static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]

    static func targetCodecID(_ codec: TranscodeSettings.Codec) -> AVCodecID {
        codec == .hevc ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264
    }

    /// True when the output would have the source's codec and size, so a stream copy replaces the re-encode.
    static func canCopy(_ parameters: UnsafeMutablePointer<AVCodecParameters>, settings: TranscodeSettings) -> Bool {
        let width = Int(parameters.pointee.width), height = Int(parameters.pointee.height)
        let size = TranscodeMath.outputSize(width: width, height: height, maxLongEdge: settings.maxLongEdge)
        return parameters.pointee.codec_id == targetCodecID(settings.codec) && size.width == width && size.height == height
    }

    /// The stream's frame rate, falling back to the real base rate and then to 30.
    static func frameRate(of stream: UnsafeMutablePointer<AVStream>) -> AVRational {
        var rate = stream.pointee.avg_frame_rate
        if rate.num <= 0 || rate.den <= 0 { rate = stream.pointee.r_frame_rate }
        if rate.num <= 0 || rate.den <= 0 { rate = AVRational(num: 30, den: 1) }
        return rate
    }

    /// The stream's duration in seconds, from the container when it knows, else from the stream; 0 if neither.
    static func duration(of input: DemuxInput, stream: UnsafeMutablePointer<AVStream>) -> Double {
        if input.context.pointee.duration > 0 { return Double(input.context.pointee.duration) / Double(FF.timeBase) }
        let seconds = Double(stream.pointee.duration) * av_q2d(stream.pointee.time_base)
        return seconds > 0 ? seconds : 0
    }
}

/// An MP4 written through FFmpeg's file protocol, which can seek back to finish the `moov`.
final class MP4FileOutput {
    let context: UnsafeMutablePointer<AVFormatContext>
    private let path: String

    init(path: String) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let result = avformat_alloc_output_context2(&context, nil, "mp4", path)
        guard result >= 0, let context else { throw VideoEngineError.failure("create MP4 output", result) }
        self.context = context
        self.path = path
    }

    deinit {
        if context.pointee.pb != nil { avio_closep(&context.pointee.pb) }
        avformat_free_context(context)
    }

    var needsGlobalHeader: Bool { context.pointee.oformat.pointee.flags & FF.avfmtGlobalHeader != 0 }

    func addStream() throws -> UnsafeMutablePointer<AVStream> {
        guard let stream = avformat_new_stream(context, nil) else { throw VideoEngineError.outOfMemory }
        return stream
    }

    /// An output stream with the parameters of `stream`, for copying its packets.
    func addCopy(of stream: UnsafeMutablePointer<AVStream>) throws -> UnsafeMutablePointer<AVStream> {
        let out = try addStream()
        let copied = avcodec_parameters_copy(out.pointee.codecpar, stream.pointee.codecpar)
        guard copied >= 0 else { throw VideoEngineError.failure("copy stream parameters", copied) }
        let parameters = out.pointee.codecpar!
        // AVPlayer shows a black picture for hev1 in a progressive MP4, which is what the muxer writes for
        // HEVC unless told otherwise; every other codec gets the muxer's own tag.
        parameters.pointee.codec_tag = parameters.pointee.codec_id == AV_CODEC_ID_HEVC ? FF.tag("hvc1") : 0
        return out
    }

    func start() throws {
        let opened = avio_open(&context.pointee.pb, path, FF.avioFlagWrite)
        guard opened >= 0 else { throw VideoEngineError.writeFailed(code: opened) }
        let header = avformat_write_header(context, nil)
        guard header >= 0 else { throw VideoEngineError.headerFailed(code: header, message: FF.errorString(header)) }
    }

    func write(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        let result = av_interleaved_write_frame(context, packet)
        guard result >= 0 else { throw VideoEngineError.writeFailed(code: result) }
    }

    /// Writes the trailer and closes the file; a write error from either surfaces here.
    func finish() throws {
        let trailer = av_write_trailer(context)
        guard trailer >= 0 else { throw VideoEngineError.writeFailed(code: trailer) }
        let closed = avio_closep(&context.pointee.pb)
        guard closed >= 0 else { throw VideoEngineError.writeFailed(code: closed) }
    }
}

/// Copies the packets of `indices` into a new MP4 without decoding. `onTime` gets the source time in seconds
/// of each packet of the first stream.
func copyStreams(
    from input: DemuxInput, indices: [Int], to path: String, control: RunControl, onTime: (Double) -> Void
) throws {
    let output = try MP4FileOutput(path: path)
    var outputs: [Int: UnsafeMutablePointer<AVStream>] = [:]
    for index in indices {
        guard let stream = input.stream(index) else { continue }
        outputs[index] = try output.addCopy(of: stream)
    }
    try output.start()
    let packet = try FFPacket()
    while true {
        if control.isStopped { throw CancellationError() }
        guard try input.nextPacket(into: packet.pointer) else { break }
        defer { av_packet_unref(packet.pointer) }
        let index = Int(packet.pointer.pointee.stream_index)
        guard let out = outputs[index], let stream = input.stream(index) else { continue }
        if index == indices.first {
            let pts = packet.pointer.pointee.pts != FF.noPTS ? packet.pointer.pointee.pts : packet.pointer.pointee.dts
            if pts != FF.noPTS { onTime(Double(pts) * av_q2d(stream.pointee.time_base)) }
        }
        av_packet_rescale_ts(packet.pointer, stream.pointee.time_base, out.pointee.time_base)
        packet.pointer.pointee.stream_index = out.pointee.index
        packet.pointer.pointee.pos = -1
        try output.write(packet.pointer)
    }
    try output.finish()
}

/// Forwards progress in steps of at least 1%, plus the final 1. Confined to the worker thread.
final class ProgressGate {
    private var last = -1.0
    private let sink: @Sendable (Double) -> Void

    init(_ sink: @escaping @Sendable (Double) -> Void) {
        self.sink = sink
    }

    var lastReported: Double { max(0, last) }

    func report(_ value: Double) {
        let clamped = min(1, max(0, value))
        guard clamped - last >= 0.01 || (clamped == 1 && last < 1) else { return }
        last = clamped
        sink(clamped)
    }
}

/// "m:ss" for an ETA, or a dash when unknown.
func clockText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "—" }
    let whole = Int(seconds.rounded())
    return String(format: "%d:%02d", whole / 60, whole % 60)
}
