import Foundation

/// What an on-device re-encode produces. Codable, so an app can persist it with an interrupted job.
public struct TranscodeSettings: Sendable, Codable, Equatable {
    public enum Codec: String, Sendable, Codable, CaseIterable {
        case h264, hevc
    }

    public enum Quality: String, Sendable, Codable, CaseIterable {
        case low, medium, high
    }

    public var codec: Codec
    public var quality: Quality
    /// Longest output edge in pixels; nil keeps the source size.
    public var maxLongEdge: Int?
    /// Target video bit rate in bits per second, replacing the quality ladder.
    public var bitrateOverride: Int?

    public init(codec: Codec, quality: Quality, maxLongEdge: Int? = nil, bitrateOverride: Int? = nil) {
        self.codec = codec
        self.quality = quality
        self.maxLongEdge = maxLongEdge
        self.bitrateOverride = bitrateOverride
    }
}

/// Output size and bit rate of a re-encode: one copy for every transcode path and for size estimates.
public enum TranscodeMath {
    /// Scales the long edge down to `maxLongEdge`, keeping the aspect ratio, and rounds both sides to even
    /// numbers, which the encoders require. A missing size (under 2 pixels) becomes 1280x720.
    public static func outputSize(width: Int, height: Int, maxLongEdge: Int?) -> (width: Int, height: Int) {
        var w = Double(abs(width)), h = Double(abs(height))
        if w < 2 || h < 2 { return (1280, 720) }
        if let maxLongEdge, Double(maxLongEdge) < max(w, h) {
            let scale = Double(maxLongEdge) / max(w, h)
            w *= scale
            h *= scale
        }
        return (max(2, Int((w / 2).rounded()) * 2), max(2, Int((h / 2).rounded()) * 2))
    }

    /// The override when set; otherwise megabits per megapixel at 30 fps for the quality, scaled for the
    /// frame rate and codec, never above the quality's share of `sourceBitrate` (0 = unknown) and never
    /// below 500 kbit/s.
    public static func videoBitrate(
        width: Int, height: Int, fps: Double, settings: TranscodeSettings, sourceBitrate: Int = 0
    ) -> Int {
        if let override = settings.bitrateOverride, override > 0 { return override }
        let megapixels = Double(width * height) / 1_000_000
        var bits = settings.quality.megabitsPerMegapixel * megapixels * (fps / 30) * settings.codec.bitrateFactor * 1_000_000
        // A re-encode must never inflate the bit rate: an 8 Mbit/s source does not become 20 Mbit/s.
        if sourceBitrate > 0 { bits = min(bits, Double(sourceBitrate) * settings.quality.sourceShare) }
        return max(500_000, Int(bits))
    }
}

extension TranscodeSettings.Quality {
    /// H.264 megabits per second per megapixel at 30 fps.
    var megabitsPerMegapixel: Double {
        switch self {
        case .low: 2
        case .medium: 4
        case .high: 7
        }
    }

    /// Ceiling as a share of the source bit rate.
    var sourceShare: Double {
        switch self {
        case .low: 0.35
        case .medium: 0.6
        case .high: 1
        }
    }
}

extension TranscodeSettings.Codec {
    /// HEVC reaches similar quality at a lower bit rate than H.264.
    var bitrateFactor: Double { self == .hevc ? 0.6 : 1 }
    var encoderName: String { self == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox" }
}

/// Callbacks of a running transcode, made on the engine's worker thread.
public struct TranscodeObserver: Sendable {
    /// Fraction done, 0 to 1, in steps of at least 1%.
    public var progress: @Sendable (Double) -> Void
    /// One event line per call.
    public var log: @Sendable (String) -> Void
    /// Replaces a single live status line (speed, ETA); an empty string clears it.
    public var status: @Sendable (String) -> Void

    public init(
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { _ in },
        status: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.progress = progress
        self.log = log
        self.status = status
    }
}

/// An on-device re-encode of a local file into an MP4.
public protocol MediaTranscoder: AnyObject, Sendable {
    /// Throws `CancellationError` when cancelled; the caller removes a partial `output`.
    func run(input: URL, output: URL, settings: TranscodeSettings, observer: TranscodeObserver) async throws
    /// Never blocks, so it is safe from a background-task expiry handler. A cancelled transcoder stays cancelled.
    func cancel()
}
