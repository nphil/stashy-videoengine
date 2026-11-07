import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// Decodes one audio stream and encodes it to AAC for the MP4 output. Encoded packets carry timestamps in
/// the source stream's time base and its stream index, so they take the same origin shift as the copied
/// streams. Confined to the remux thread.
final class AudioReencoder {
    let streamIndex: Int
    private let decoder: FFCodecContext
    private let encoder: FFCodecContext
    private let decoded: FFFrame
    private let resampled: FFFrame
    private let encoderInput: FFFrame
    private let sourceTimeBase: AVRational
    private let channels: Int32
    private var resampler: OpaquePointer?
    private let fifo: OpaquePointer
    /// Next encoder timestamp, in samples; set from the first decoded frame.
    private var nextPTS: Int64?

    /// Opens the decoder for `stream` and an AAC encoder, and describes the encoded audio on `output`.
    init(stream: UnsafeMutablePointer<AVStream>, output: UnsafeMutablePointer<AVStream>, channels: Int, bitRate: Int) throws {
        let parameters: UnsafeMutablePointer<AVCodecParameters> = stream.pointee.codecpar
        let codecName = String(cString: avcodec_get_name(parameters.pointee.codec_id))
        guard let decoderCodec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw VideoEngineError.decoderUnavailable(codec: codecName)
        }
        streamIndex = Int(stream.pointee.index)
        sourceTimeBase = stream.pointee.time_base
        decoder = try FFCodecContext(codec: decoderCodec)
        var result = avcodec_parameters_to_context(decoder.pointer, parameters)
        guard result >= 0 else { throw VideoEngineError.failure("configure \(codecName) decoder", result) }
        decoder.pointer.pointee.pkt_timebase = stream.pointee.time_base
        var decoderOptions: OpaquePointer?
        defer { av_dict_free(&decoderOptions) }
        // TrueHD, DTS and Dolby decoders mix down themselves; plain "5.1" would mean 5.1(back).
        if Int(parameters.pointee.ch_layout.nb_channels) > channels {
            av_dict_set(&decoderOptions, "downmix", channels == 6 ? "5.1(side)" : "stereo", 0)
        }
        result = avcodec_open2(decoder.pointer, decoderCodec, &decoderOptions)
        guard result >= 0 else { throw VideoEngineError.failure("open \(codecName) decoder", result) }

        // AudioToolbox's encoder when the build has it, FFmpeg's own otherwise.
        guard let encoderCodec = avcodec_find_encoder_by_name("aac_at") ?? avcodec_find_encoder(AV_CODEC_ID_AAC) else {
            throw VideoEngineError.encoderUnavailable(name: "aac")
        }
        encoder = try FFCodecContext(codec: encoderCodec)
        let context = encoder.pointer
        context.pointee.sample_fmt = Self.supported(AV_CODEC_CONFIG_SAMPLE_FORMAT, context, encoderCodec, as: AVSampleFormat.self)?
            .first ?? AV_SAMPLE_FMT_FLTP
        let sourceRate = parameters.pointee.sample_rate
        let rates = Self.supported(AV_CODEC_CONFIG_SAMPLE_RATE, context, encoderCodec, as: Int32.self)
        context.pointee.sample_rate = sourceRate > 0 && rates.map({ $0.contains(sourceRate) }) ?? (sourceRate <= 48_000)
            ? sourceRate : 48_000
        if let layout = Self.supported(AV_CODEC_CONFIG_CHANNEL_LAYOUT, context, encoderCodec, as: AVChannelLayout.self)?
            .first(where: { Int($0.nb_channels) == channels }) {
            var chosen = layout
            result = av_channel_layout_copy(&context.pointee.ch_layout, &chosen)
            guard result >= 0 else { throw VideoEngineError.failure("set AAC channel layout", result) }
        } else {
            av_channel_layout_default(&context.pointee.ch_layout, Int32(channels))
        }
        context.pointee.bit_rate = Int64(bitRate)
        context.pointee.time_base = AVRational(num: 1, den: context.pointee.sample_rate)
        // MP4 keeps the AudioSpecificConfig in the sample entry.
        context.pointee.flags |= FF.codecFlagGlobalHeader
        result = avcodec_open2(context, encoderCodec, nil)
        guard result >= 0 else { throw VideoEngineError.failure("open AAC encoder", result) }
        result = avcodec_parameters_from_context(output.pointee.codecpar, context)
        guard result >= 0 else { throw VideoEngineError.failure("describe AAC stream", result) }
        output.pointee.time_base = context.pointee.time_base
        self.channels = context.pointee.ch_layout.nb_channels

        decoded = try FFFrame()
        resampled = try FFFrame()
        encoderInput = try FFFrame()
        guard let resampler = swr_alloc() else { throw VideoEngineError.outOfMemory }
        self.resampler = resampler
        guard let fifo = av_audio_fifo_alloc(context.pointee.sample_fmt, self.channels, 4096) else {
            swr_free(&self.resampler)
            throw VideoEngineError.outOfMemory
        }
        self.fifo = fifo
    }

    deinit {
        swr_free(&resampler)
        av_audio_fifo_free(fifo)
    }

    /// Takes a source packet's reference, or nil at the end of the stream, and returns the AAC packets
    /// ready so far. A packet the decoder rejects loses its samples, not the run.
    func process(_ packet: UnsafeMutablePointer<AVPacket>?) throws -> [FFPacket] {
        _ = avcodec_send_packet(decoder.pointer, packet)
        if let packet { av_packet_unref(packet) }
        var output: [FFPacket] = []
        while true {
            let received = avcodec_receive_frame(decoder.pointer, decoded.pointer)
            if received == FF.eagain || received == FF.averrorEOF { break }
            guard received >= 0 else { throw VideoEngineError.failure("decode audio", received) }
            if nextPTS == nil {
                let start = decoded.pointer.pointee.best_effort_timestamp
                nextPTS = start == FF.noPTS ? 0 : av_rescale_q(start, sourceTimeBase, encoder.pointer.pointee.time_base)
            }
            try resample(decoded.pointer)
            av_frame_unref(decoded.pointer)
            try encode(into: &output, final: false)
        }
        if packet == nil {
            try resample(nil)
            try encode(into: &output, final: true)
            let flushed = avcodec_send_frame(encoder.pointer, nil)
            guard flushed >= 0 || flushed == FF.averrorEOF else { throw VideoEngineError.failure("flush AAC encoder", flushed) }
            try receive(into: &output)
        }
        return output
    }

    /// Converts a decoded frame, or the resampler's remaining samples for nil, into the FIFO.
    private func resample(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
        let context = encoder.pointer
        let out = resampled.pointer
        av_frame_unref(out)
        out.pointee.format = context.pointee.sample_fmt.rawValue
        out.pointee.sample_rate = context.pointee.sample_rate
        var result = av_channel_layout_copy(&out.pointee.ch_layout, &context.pointee.ch_layout)
        guard result >= 0 else { throw VideoEngineError.failure("set resampler layout", result) }
        // The first frame configures the resampler from its own format, which can differ from what the
        // container declared.
        result = swr_convert_frame(resampler, out, frame)
        guard result >= 0 else { throw VideoEngineError.failure("resample audio", result) }
        guard out.pointee.nb_samples > 0 else { return }
        let samples = out.pointee.nb_samples
        let written = out.pointee.extended_data.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: Int(channels)) {
            av_audio_fifo_write(fifo, $0, samples)
        }
        guard written == samples else { throw VideoEngineError.failure("queue audio", written < 0 ? written : FF.enomem) }
    }

    /// Encodes whole frames from the FIFO; with `final`, the short remainder too.
    private func encode(into output: inout [FFPacket], final: Bool) throws {
        let context = encoder.pointer
        let frameSize = context.pointee.frame_size > 0 ? context.pointee.frame_size : 1024
        while av_audio_fifo_size(fifo) >= frameSize || (final && av_audio_fifo_size(fifo) > 0) {
            let count = min(av_audio_fifo_size(fifo), frameSize)
            let input = encoderInput.pointer
            av_frame_unref(input)
            input.pointee.nb_samples = count
            input.pointee.format = context.pointee.sample_fmt.rawValue
            input.pointee.sample_rate = context.pointee.sample_rate
            var result = av_channel_layout_copy(&input.pointee.ch_layout, &context.pointee.ch_layout)
            guard result >= 0 else { throw VideoEngineError.failure("set AAC frame layout", result) }
            result = av_frame_get_buffer(input, 0)
            guard result >= 0 else { throw VideoEngineError.failure("allocate AAC frame", result) }
            let read = input.pointee.extended_data.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: Int(channels)) {
                av_audio_fifo_read(fifo, $0, count)
            }
            guard read == count else { throw VideoEngineError.failure("dequeue audio", read < 0 ? read : FF.eio) }
            let pts = nextPTS ?? 0
            input.pointee.pts = pts
            nextPTS = pts + Int64(count)
            result = avcodec_send_frame(context, input)
            guard result >= 0 else { throw VideoEngineError.failure("encode audio", result) }
            try receive(into: &output)
        }
    }

    private func receive(into output: inout [FFPacket]) throws {
        let context = encoder.pointer
        while true {
            let owner = try FFPacket()
            let result = avcodec_receive_packet(context, owner.pointer)
            if result == FF.eagain || result == FF.averrorEOF { return }
            guard result >= 0 else { throw VideoEngineError.failure("encode audio", result) }
            av_packet_rescale_ts(owner.pointer, context.pointee.time_base, sourceTimeBase)
            owner.pointer.pointee.stream_index = Int32(streamIndex)
            output.append(owner)
        }
    }

    /// The encoder's list for `config`, or nil when it accepts anything.
    private static func supported<T>(
        _ config: AVCodecConfig, _ context: UnsafeMutablePointer<AVCodecContext>, _ codec: UnsafePointer<AVCodec>,
        as type: T.Type
    ) -> UnsafeBufferPointer<T>? {
        var values: UnsafeRawPointer?
        var count: Int32 = 0
        guard avcodec_get_supported_config(context, codec, config, 0, &values, &count) >= 0, let values, count > 0 else {
            return nil
        }
        return UnsafeBufferPointer(start: values.assumingMemoryBound(to: T.self), count: Int(count))
    }
}
