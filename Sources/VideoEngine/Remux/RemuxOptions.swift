import Foundation

/// The sample entry an HEVC stream gets in the MP4 output.
public struct HEVCTag: Sendable, Equatable {
    /// Four-character code to force, or nil to let the muxer choose (it picks "hev1").
    public var fourCC: String?

    public init(fourCC: String?) {
        self.fourCC = fourCC
    }

    public static let muxerDefault = HEVCTag(fourCC: nil)
    /// Parameter sets only in the sample entry; the form Apple documents for HLS.
    public static let hvc1 = HEVCTag(fourCC: "hvc1")
    /// Parameter sets allowed in-band as well.
    public static let hev1 = HEVCTag(fourCC: "hev1")
}

public struct RemuxOptions: Sendable {
    public var hevcTag: HEVCTag = .muxerDefault
    /// Extra MP4 muxer options, such as `["strict": "unofficial"]`.
    public var muxerOptions: [String: String] = [:]
    /// Added to `frag_keyframe+empty_moov+default_base_moof`.
    public var extraMovflags: [String] = []
    public var ioBufferBytes = 256 << 10
    /// How far production may run ahead of the playhead before it waits.
    public var paceLeadSeconds: TimeInterval = 75
    /// Smaller sources are remuxed to the end without pacing, so scrubbing never waits on them.
    public var paceMinSourceBytes: Int64 = 200 << 20
    /// Seconds allowed for opening the source and reading its stream info.
    public var openTimeout: TimeInterval = 30
    /// Seconds without a new packet before the run fails with `.timedOut`.
    public var stallTimeout: TimeInterval = 20
    /// Duration for the playlist; nil uses the container's.
    public var knownDuration: TimeInterval?
    public var tempDirectory = FileManager.default.temporaryDirectory
    public var tempFilePrefix = "videoengine-stream-"

    public init() {}
}

public struct RemuxProgress: Sendable, Equatable {
    public var bytesWritten: Int64
    /// Media time produced so far, on the output timeline (0 at the run's start point).
    public var mediaSeconds: TimeInterval
    public var packets: Int
    /// True while production waits for the playhead.
    public var isPaced: Bool

    public init(bytesWritten: Int64 = 0, mediaSeconds: TimeInterval = 0, packets: Int = 0, isPaced: Bool = false) {
        self.bytesWritten = bytesWritten
        self.mediaSeconds = mediaSeconds
        self.packets = packets
        self.isPaced = isPaced
    }
}

public enum RemuxEvent: Sendable {
    case opened(MediaInfo)
    /// The init segment is on disk. `videoSampleEntry` (hvc1, hev1, avc1, ...) is the first thing to check
    /// when the picture stays black.
    case headerWritten(initBytes: Int, videoSampleEntry: String?)
    /// Sent at most twice a second.
    case progress(RemuxProgress)
    case finished(RemuxProgress)
    /// The run was ended by `stop()` or replaced by `seek(to:)`.
    case stopped(RemuxProgress)
    case failed(VideoEngineError, RemuxProgress)
}
