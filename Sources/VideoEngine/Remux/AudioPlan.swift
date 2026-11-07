import Foundation

/// Which audio stream a run plays and how it gets into the MP4.
public struct AudioPolicy: Sendable, Equatable {
    /// Stream index of the audio the viewer picked. Nil takes the stream flagged default, else the first.
    public var preferredIndex: Int?
    /// Codecs copied when their gate passes; everything else is re-encoded to AAC.
    public var copyable: Set<String>
    /// AAC bit rate for re-encoded mono and stereo.
    public var stereoBitRate: Int
    /// AAC bit rate for re-encoded 5.1, which is what anything above two channels becomes.
    public var surroundBitRate: Int
    /// E-AC-3 with more than six channels keeps its 5.1 core: the MP4 muxer cannot describe a 7.1
    /// dependent substream or a second independent one.
    public var eac3Core: Bool

    public init(preferredIndex: Int? = nil, copyable: Set<String> = AudioPolicy.provenCopyable,
                stereoBitRate: Int = 192_000, surroundBitRate: Int = 384_000, eac3Core: Bool = true) {
        self.preferredIndex = preferredIndex
        self.copyable = copyable
        self.stereoBitRate = stereoBitRate
        self.surroundBitRate = surroundBitRate
        self.eac3Core = eac3Core
    }

    /// Formats AVPlayer is known to play when copied. MP3, Opus, multichannel FLAC and ALAC, implicit-SBR
    /// HE-AAC and AAC with a program config element are re-encoded until a device test proves them.
    public static let provenCopyable: Set<String> = ["aac", "ac3", "eac3", "flac", "alac"]
}

/// The facts about one audio stream that its plan is decided from.
struct AudioStreamFacts: Equatable {
    var index: Int
    var codec: String
    var channels: Int
    var sampleRate: Int
    /// Bits per decoded sample, 0 when the container does not say.
    var bitsPerSample: Int
    var isDefault: Bool
    /// The AAC AudioSpecificConfig; empty for other codecs.
    var audioSpecificConfig: [UInt8] = []
}

/// The one audio stream a run maps, and whether it is copied or re-encoded. HLS allows a single audio
/// track per variant, and the muxer enables only the first one anyway.
struct AudioPlan: Equatable {
    enum Action: Equatable {
        case copy
        /// The `eac3_core` filter keeps the first independent substream: 5.1 at most.
        case copyCore
        case reencode(channels: Int, bitRate: Int)
    }

    var streamIndex: Int
    var codec: String
    var action: Action

    /// The codec as the muxer receives it untouched, or nil when it is re-encoded.
    var copiedCodec: String? {
        if case .reencode = action { return nil }
        return codec
    }

    static func decide(_ streams: [AudioStreamFacts], policy: AudioPolicy, forceReencode: Bool = false) -> AudioPlan? {
        let preferred = policy.preferredIndex.flatMap { index in streams.first { $0.index == index } }
        guard let stream = preferred ?? streams.first(where: \.isDefault) ?? streams.first else { return nil }
        let surround = stream.channels > 2
        let reencode = Action.reencode(
            channels: surround ? 6 : 2, bitRate: surround ? policy.surroundBitRate : policy.stereoBitRate
        )
        var action = reencode
        if !forceReencode, policy.copyable.contains(stream.codec) {
            switch stream.codec {
            case "aac":
                if isPlayableAAC(stream.audioSpecificConfig) { action = .copy }
            case "eac3":
                action = stream.channels > 6 && policy.eac3Core ? .copyCore : .copy
            case "flac", "alac":
                if stream.channels <= 2, stream.sampleRate <= 96_000, stream.bitsPerSample <= 24 { action = .copy }
            default:
                action = .copy
            }
        }
        return AudioPlan(streamIndex: stream.index, codec: stream.codec, action: action)
    }

    /// AAC-LC with a channel configuration, or HE-AAC with explicit SBR (object type 5 or 29). Implicit
    /// SBR and a program config element (configuration 0) are unproven in AVPlayer.
    static func isPlayableAAC(_ config: [UInt8]) -> Bool {
        func bits(_ start: Int, _ count: Int) -> Int? {
            guard (start + count + 7) / 8 <= config.count else { return nil }
            var value = 0
            for bit in start..<start + count { value = value << 1 | Int(config[bit / 8] >> UInt8(7 - bit % 8) & 1) }
            return value
        }
        guard let objectType = bits(0, 5), let frequencyIndex = bits(5, 4) else { return false }
        if objectType == 5 || objectType == 29 { return true }
        // Frequency index 15 is followed by the rate itself in 24 bits.
        guard objectType == 2, let channels = bits(frequencyIndex == 15 ? 33 : 9, 4) else { return false }
        return channels != 0
    }
}
