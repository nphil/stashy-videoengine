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

extension VideoEngineError {
    static let outOfMemory = VideoEngineError.ffmpeg(code: FF.enomem, message: "out of memory")

    /// An FFmpeg failure with its error text, prefixed by the step that failed.
    static func failure(_ step: String, _ code: Int32) -> VideoEngineError {
        .ffmpeg(code: code, message: "\(step): \(FF.errorString(code))")
    }
}
