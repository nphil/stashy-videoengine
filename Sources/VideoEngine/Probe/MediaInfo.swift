import Libavcodec
import Libavformat
import Libavutil

public struct VideoStreamInfo: Sendable, Equatable {
    /// Stream index in the container.
    public var index: Int
    /// FFmpeg codec name, such as "hevc", "h264" or "av1".
    public var codec: String
    public var profile: String?
    /// FFmpeg pixel format name, such as "yuv420p10le".
    public var pixelFormat: String?
    public var width: Int
    public var height: Int
    public var bitDepth: Int?
    /// FFmpeg transfer name, such as "smpte2084" (PQ) or "arib-std-b67" (HLG); nil when unspecified.
    public var colorTransfer: String?
    /// FFmpeg primaries name, such as "bt2020"; nil when unspecified.
    public var colorPrimaries: String?

    public init(
        index: Int, codec: String, profile: String? = nil, pixelFormat: String? = nil, width: Int, height: Int,
        bitDepth: Int? = nil, colorTransfer: String? = nil, colorPrimaries: String? = nil
    ) {
        self.index = index
        self.codec = codec
        self.profile = profile
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
    }

    /// Whether Apple's H.264/HEVC decoders take this pixel format: 4:2:0 at 8 or 10 bits. 4:2:2, 4:4:4,
    /// RGB and 12-bit need a transcode. An unknown format counts as decodable, so playback is attempted.
    public var isAppleDecodable: Bool {
        guard let format = pixelFormat?.lowercased() else { return true }
        return !["422", "444", "12le", "12be", "gbr"].contains { format.contains($0) }
    }
}

public struct AudioStreamInfo: Sendable, Equatable {
    public var index: Int
    public var codec: String
    public var channels: Int
    public var sampleRate: Int
    /// ISO 639 language code from the container, such as "eng".
    public var language: String?
    public var title: String?
    public var isDefault: Bool

    public init(
        index: Int, codec: String, channels: Int, sampleRate: Int, language: String? = nil, title: String? = nil,
        isDefault: Bool = false
    ) {
        self.index = index
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.language = language
        self.title = title
        self.isDefault = isDefault
    }
}

public struct SubtitleStreamInfo: Sendable, Equatable {
    public var index: Int
    /// FFmpeg codec name, such as "subrip", "ass" or "hdmv_pgs_subtitle".
    public var codec: String
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    public var isForced: Bool
    /// True for picture-based subtitles (PGS, VobSub, DVB) that need OCR or burn-in rather than text output.
    public var isBitmap: Bool

    public init(
        index: Int, codec: String, language: String? = nil, title: String? = nil, isDefault: Bool = false,
        isForced: Bool = false, isBitmap: Bool = false
    ) {
        self.index = index
        self.codec = codec
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
        self.isBitmap = isBitmap
    }
}

public struct MediaInfo: Sendable, Equatable {
    /// FFmpeg demuxer name, such as "matroska,webm" or "mov,mp4,m4a,3gp,3g2,mj2".
    public var container: String
    public var duration: TimeInterval?
    /// Overall bit rate in bits per second.
    public var bitRate: Int?
    public var video: [VideoStreamInfo]
    public var audio: [AudioStreamInfo]
    public var subtitles: [SubtitleStreamInfo]

    public init(
        container: String, duration: TimeInterval? = nil, bitRate: Int? = nil, video: [VideoStreamInfo] = [],
        audio: [AudioStreamInfo] = [], subtitles: [SubtitleStreamInfo] = []
    ) {
        self.container = container
        self.duration = duration
        self.bitRate = bitRate
        self.video = video
        self.audio = audio
        self.subtitles = subtitles
    }
}

extension MediaInfo {
    /// Reads what an opened demuxer knows about its streams. Cover art, which containers store as a video
    /// stream, is left out.
    init(format: UnsafeMutablePointer<AVFormatContext>) {
        let context = format.pointee
        self.init(
            container: FF.string(context.iformat?.pointee.name) ?? "unknown",
            duration: context.duration > 0 ? Double(context.duration) / Double(FF.timeBase) : nil,
            bitRate: context.bit_rate > 0 ? Int(context.bit_rate) : nil
        )
        for i in 0..<Int(context.nb_streams) {
            guard let stream = context.streams[i], let parameters = stream.pointee.codecpar else { continue }
            let codecID = parameters.pointee.codec_id
            let codec = FF.string(avcodec_get_name(codecID)) ?? "unknown"
            let disposition = stream.pointee.disposition
            let metadata = stream.pointee.metadata
            switch parameters.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO where disposition & FF.dispositionAttachedPicture == 0:
                video.append(VideoStreamInfo(stream: stream, codec: codec))
            case AVMEDIA_TYPE_AUDIO:
                audio.append(AudioStreamInfo(
                    index: i, codec: codec,
                    channels: Int(parameters.pointee.ch_layout.nb_channels),
                    sampleRate: Int(parameters.pointee.sample_rate),
                    language: Self.tag("language", in: metadata), title: Self.tag("title", in: metadata),
                    isDefault: disposition & FF.dispositionDefault != 0
                ))
            case AVMEDIA_TYPE_SUBTITLE:
                let properties = avcodec_descriptor_get(codecID)?.pointee.props ?? 0
                subtitles.append(SubtitleStreamInfo(
                    index: i, codec: codec,
                    language: Self.tag("language", in: metadata), title: Self.tag("title", in: metadata),
                    isDefault: disposition & FF.dispositionDefault != 0,
                    isForced: disposition & FF.dispositionForced != 0,
                    isBitmap: properties & FF.codecPropBitmapSubtitle != 0
                ))
            default:
                continue
            }
        }
    }

    static func tag(_ key: String, in metadata: OpaquePointer?) -> String? {
        FF.string(av_dict_get(metadata, key, nil, 0)?.pointee.value)
    }
}

extension VideoStreamInfo {
    init(stream: UnsafeMutablePointer<AVStream>, codec: String) {
        let parameters = stream.pointee.codecpar.pointee
        let pixelFormat = AVPixelFormat(rawValue: parameters.format)
        let depth = av_pix_fmt_desc_get(pixelFormat)?.pointee.comp.0.depth
        self.init(
            index: Int(stream.pointee.index),
            codec: codec,
            profile: FF.string(avcodec_profile_name(parameters.codec_id, parameters.profile)),
            pixelFormat: FF.string(av_get_pix_fmt_name(pixelFormat)),
            width: Int(parameters.width),
            height: Int(parameters.height),
            bitDepth: depth.map { Int($0) } ?? (parameters.bits_per_raw_sample > 0 ? Int(parameters.bits_per_raw_sample) : nil),
            colorTransfer: parameters.color_trc == AVCOL_TRC_UNSPECIFIED ? nil : FF.string(av_color_transfer_name(parameters.color_trc)),
            colorPrimaries: parameters.color_primaries == AVCOL_PRI_UNSPECIFIED ? nil : FF.string(av_color_primaries_name(parameters.color_primaries))
        )
    }
}
