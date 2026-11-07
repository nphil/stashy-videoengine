import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale

/// What to do with one decoded frame.
enum FrameDecision {
    /// Encode it with this pts, in the encoder's time base.
    case encode(pts: Int64)
    case skip
    /// Stop decoding: the frame is past the range being encoded.
    case stop
}

/// Decodes one video stream, with VideoToolbox when the device offers it, converts each frame to NV12 at
/// the output size and encodes it with the VideoToolbox encoder into a stream of `output`. Confined to the
/// worker thread that made it.
final class VideoReencoder {
    let outStream: UnsafeMutablePointer<AVStream>
    let size: (width: Int, height: Int)
    let bitrate: Int
    let frameRate: AVRational
    private let output: MP4FileOutput
    private let decoder: FFCodecContext
    private let encoder: FFCodecContext
    private let frame: FFFrame
    private let packet: FFPacket
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private let log: (String) -> Void
    private var loggedDecodePath = false

    var encoderTimeBase: AVRational { encoder.pointer.pointee.time_base }

    init(stream: UnsafeMutablePointer<AVStream>, output: MP4FileOutput, settings: TranscodeSettings, log: @escaping (String) -> Void) throws {
        let parameters = stream.pointee.codecpar!
        let codecID = parameters.pointee.codec_id
        let codecName = FF.string(avcodec_get_name(codecID)) ?? "unknown"
        guard let decoderCodec = avcodec_find_decoder(codecID) else { throw VideoEngineError.decoderUnavailable(codec: codecName) }
        let decoder = try FFCodecContext(codec: decoderCodec)
        guard avcodec_parameters_to_context(decoder.pointer, parameters) >= 0 else {
            throw VideoEngineError.decoderUnavailable(codec: codecName)
        }
        decoder.pointer.pointee.thread_count = 0
        // The device and get_format must be in place before the decoder opens; without them it decodes on
        // the CPU. The decoder owns the device reference from here on.
        var device: UnsafeMutablePointer<AVBufferRef>?
        if av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0, let device {
            decoder.pointer.pointee.hw_device_ctx = device
            decoder.pointer.pointee.get_format = preferVideoToolbox
        }
        guard avcodec_open2(decoder.pointer, decoderCodec, nil) >= 0 else {
            throw VideoEngineError.decoderUnavailable(codec: codecName)
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        log("Decode: requesting \(device != nil ? "VideoToolbox hardware" : "software (\(cores) cores)")")

        let rate = TranscodeRules.frameRate(of: stream)
        let fps = av_q2d(rate)
        let size = TranscodeMath.outputSize(
            width: Int(parameters.pointee.width), height: Int(parameters.pointee.height), maxLongEdge: settings.maxLongEdge
        )
        let sourceBitrate = Int(parameters.pointee.bit_rate)
        var bitrate = TranscodeMath.videoBitrate(
            width: size.width, height: size.height, fps: fps, settings: settings, sourceBitrate: sourceBitrate
        )
        // Re-encoding into the source's own codec only pays off below the source's bit rate, override or not.
        if codecID == TranscodeRules.targetCodecID(settings.codec), sourceBitrate > 100_000 {
            bitrate = min(bitrate, sourceBitrate)
        }

        let encoderName = settings.codec.encoderName
        guard let encoderCodec = avcodec_find_encoder_by_name(encoderName) else {
            throw VideoEngineError.encoderUnavailable(name: encoderName)
        }
        let encoder = try FFCodecContext(codec: encoderCodec)
        let context = encoder.pointer
        context.pointee.width = Int32(size.width)
        context.pointee.height = Int32(size.height)
        context.pointee.pix_fmt = AV_PIX_FMT_NV12
        context.pointee.time_base = AVRational(num: rate.den, den: rate.num)
        context.pointee.framerate = rate
        context.pointee.bit_rate = Int64(bitrate)
        context.pointee.gop_size = Int32(max(2, Int(fps * 2)))
        context.pointee.sample_aspect_ratio = decoder.pointer.pointee.sample_aspect_ratio
        if output.needsGlobalHeader { context.pointee.flags |= FF.codecFlagGlobalHeader }
        av_opt_set(context.pointee.priv_data, "realtime", "true", 0)
        guard avcodec_open2(context, encoderCodec, nil) >= 0 else { throw VideoEngineError.encoderUnavailable(name: encoderName) }

        let outStream = try output.addStream()
        let filled = avcodec_parameters_from_context(outStream.pointee.codecpar, context)
        guard filled >= 0 else { throw VideoEngineError.failure("encoder parameters", filled) }
        // AVPlayer shows a black picture for hev1 in a progressive MP4.
        if settings.codec == .hevc { outStream.pointee.codecpar.pointee.codec_tag = FF.tag("hvc1") }
        outStream.pointee.time_base = context.pointee.time_base

        self.outStream = outStream
        self.size = size
        self.bitrate = bitrate
        self.frameRate = rate
        self.output = output
        self.decoder = decoder
        self.encoder = encoder
        self.frame = try FFFrame()
        self.packet = try FFPacket()
        self.log = log
    }

    deinit {
        sws_freeContext(scaler)
    }

    /// Sends `packet` to the decoder (nil drains it) and asks `decide` about each decoded frame, passing its
    /// best-effort timestamp in the stream's time base (nil when it has none). Returns false once `decide`
    /// answered `.stop`.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?, decide: (Int64?) -> FrameDecision) throws -> Bool {
        // A packet the decoder rejects is dropped, as a player would.
        guard avcodec_send_packet(decoder.pointer, packet) >= 0 else { return true }
        while true {
            let received = avcodec_receive_frame(decoder.pointer, frame.pointer)
            if received == FF.eagain || received == FF.averrorEOF { return true }
            guard received >= 0 else { throw VideoEngineError.failure("decode", received) }
            defer { av_frame_unref(frame.pointer) }
            let timestamp = frame.pointer.pointee.best_effort_timestamp
            switch decide(timestamp == FF.noPTS ? nil : timestamp) {
            case .skip: continue
            case .stop: return false
            case .encode(let pts): try encode(frame.pointer, pts: pts)
            }
        }
    }

    /// Drains the encoder into the output.
    func finish() throws {
        try send(nil)
    }

    private func encode(_ decoded: UnsafeMutablePointer<AVFrame>, pts: Int64) throws {
        var transferred: FFFrame?
        if decoded.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            // A VideoToolbox frame is a GPU surface: copy it to memory to scale and encode it.
            let copy = try FFFrame()
            let result = av_hwframe_transfer_data(copy.pointer, decoded, 0)
            guard result >= 0 else { throw VideoEngineError.failure("hardware frame transfer", result) }
            transferred = copy
        }
        if !loggedDecodePath {
            loggedDecodePath = true
            log("Decode path: \(transferred != nil ? "hardware (VideoToolbox) ✓" : "software (VT unavailable) ⚠︎")")
        }
        let source = transferred?.pointer ?? decoded
        var scaled: FFFrame?
        if source.pointee.format != AV_PIX_FMT_NV12.rawValue
            || Int(source.pointee.width) != size.width || Int(source.pointee.height) != size.height {
            scaler = sws_getCachedContext(
                scaler, source.pointee.width, source.pointee.height, AVPixelFormat(rawValue: source.pointee.format),
                Int32(size.width), Int32(size.height), AV_PIX_FMT_NV12, FF.swsBilinear, nil, nil, nil
            )
            guard scaler != nil else { throw VideoEngineError.failure("scaler setup", FF.einval) }
            let target = try FFFrame()
            target.pointer.pointee.format = AV_PIX_FMT_NV12.rawValue
            target.pointer.pointee.width = Int32(size.width)
            target.pointer.pointee.height = Int32(size.height)
            let allocated = av_frame_get_buffer(target.pointer, 0)
            guard allocated >= 0 else { throw VideoEngineError.failure("frame buffer", allocated) }
            let converted = sws_scale_frame(scaler, target.pointer, source)
            guard converted >= 0 else { throw VideoEngineError.failure("scale", converted) }
            scaled = target
        }
        try withExtendedLifetime((transferred, scaled)) {
            let ready = scaled?.pointer ?? source
            ready.pointee.pts = pts
            try send(ready)
        }
    }

    private func send(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
        let sent = avcodec_send_frame(encoder.pointer, frame)
        guard sent >= 0 else { throw VideoEngineError.failure("encode", sent) }
        while true {
            let received = avcodec_receive_packet(encoder.pointer, packet.pointer)
            if received == FF.eagain || received == FF.averrorEOF { return }
            guard received >= 0 else { throw VideoEngineError.failure("encode", received) }
            packet.pointer.pointee.stream_index = outStream.pointee.index
            av_packet_rescale_ts(packet.pointer, encoder.pointer.pointee.time_base, outStream.pointee.time_base)
            packet.pointer.pointee.pos = -1
            try output.write(packet.pointer)
        }
    }
}

/// get_format callback: the VideoToolbox surface format when the decoder offers it, else FFmpeg's default.
private func preferVideoToolbox(
    _ context: UnsafeMutablePointer<AVCodecContext>?, _ formats: UnsafePointer<AVPixelFormat>?
) -> AVPixelFormat {
    guard var format = formats else { return AV_PIX_FMT_NONE }
    while format.pointee != AV_PIX_FMT_NONE {
        if format.pointee == AV_PIX_FMT_VIDEOTOOLBOX { return AV_PIX_FMT_VIDEOTOOLBOX }
        format += 1
    }
    return avcodec_default_get_format(context, formats)
}
