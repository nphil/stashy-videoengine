import Libavcodec
import Libavutil

// Owners of single FFmpeg allocations, freed on deinit, so a throw part-way through a setup releases
// everything made before it. Confined to the worker thread that created them.

final class FFPacket {
    let pointer: UnsafeMutablePointer<AVPacket>

    init() throws {
        guard let pointer = av_packet_alloc() else { throw VideoEngineError.outOfMemory }
        self.pointer = pointer
    }

    deinit {
        var freed: UnsafeMutablePointer<AVPacket>? = pointer
        av_packet_free(&freed)
    }
}

final class FFFrame {
    let pointer: UnsafeMutablePointer<AVFrame>

    init() throws {
        guard let pointer = av_frame_alloc() else { throw VideoEngineError.outOfMemory }
        self.pointer = pointer
    }

    deinit {
        var freed: UnsafeMutablePointer<AVFrame>? = pointer
        av_frame_free(&freed)
    }
}

final class FFCodecContext {
    let pointer: UnsafeMutablePointer<AVCodecContext>

    init(codec: UnsafePointer<AVCodec>) throws {
        guard let pointer = avcodec_alloc_context3(codec) else { throw VideoEngineError.outOfMemory }
        self.pointer = pointer
    }

    deinit {
        var freed: UnsafeMutablePointer<AVCodecContext>? = pointer
        avcodec_free_context(&freed)
    }
}

/// A bitstream filter set up for one stream. Packets go in and come out in that stream's time base.
final class FFBitstreamFilter {
    let pointer: UnsafeMutablePointer<AVBSFContext>

    init(name: String, parameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational,
         options: [String: Int64] = [:]) throws {
        guard let filter = av_bsf_get_by_name(name) else { throw VideoEngineError.failure("find \(name)", FF.enosys) }
        var context: UnsafeMutablePointer<AVBSFContext>?
        let allocated = av_bsf_alloc(filter, &context)
        guard allocated >= 0, let context else { throw VideoEngineError.failure("allocate \(name)", allocated) }
        pointer = context
        let copied = avcodec_parameters_copy(context.pointee.par_in, parameters)
        guard copied >= 0 else { throw VideoEngineError.failure("configure \(name)", copied) }
        context.pointee.time_base_in = timeBase
        for (key, value) in options { av_opt_set_int(context.pointee.priv_data, key, value, 0) }
        let started = av_bsf_init(context)
        guard started >= 0 else { throw VideoEngineError.failure("start \(name)", started) }
    }

    deinit {
        var freed: UnsafeMutablePointer<AVBSFContext>? = pointer
        av_bsf_free(&freed)
    }

    /// Hands over a packet's reference, or nil at the end of the stream.
    func send(_ packet: UnsafeMutablePointer<AVPacket>?) throws {
        let sent = av_bsf_send_packet(pointer, packet)
        guard sent >= 0 else { throw VideoEngineError.failure("filter packet", sent) }
    }

    /// Moves the next filtered packet into `packet`; false when the filter needs input or is drained.
    func receive(into packet: UnsafeMutablePointer<AVPacket>) throws -> Bool {
        let received = av_bsf_receive_packet(pointer, packet)
        if received == FF.eagain || received == FF.averrorEOF { return false }
        guard received >= 0 else { throw VideoEngineError.failure("filter packet", received) }
        return true
    }
}

extension VideoEngineError {
    static let outOfMemory = VideoEngineError.ffmpeg(code: FF.enomem, message: "out of memory")

    /// An FFmpeg failure with its error text, prefixed by the step that failed.
    static func failure(_ step: String, _ code: Int32) -> VideoEngineError {
        .ffmpeg(code: code, message: "\(step): \(FF.errorString(code))")
    }
}
