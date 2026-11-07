import Foundation

/// A byte range inside a resource, written as `<length>@<offset>`.
public struct HLSByteRange: Sendable, Equatable {
    public var length: Int64
    public var offset: Int64

    public init(length: Int64, offset: Int64) {
        self.length = length
        self.offset = offset
    }

    var attribute: String { "\(length)@\(offset)" }
}

public struct HLSSegment: Sendable, Equatable {
    public var duration: TimeInterval
    public var uri: String
    public var byteRange: HLSByteRange?

    public init(duration: TimeInterval, uri: String, byteRange: HLSByteRange? = nil) {
        self.duration = duration
        self.uri = uri
        self.byteRange = byteRange
    }
}

/// An HLS media playlist (RFC 8216 §4.3.3) with fMP4 segments.
public struct HLSMediaPlaylist: Sendable, Equatable {
    public enum PlaylistType: String, Sendable {
        case event = "EVENT"
        case vod = "VOD"
    }

    public var targetDuration: Int
    public var mediaSequence = 0
    public var playlistType: PlaylistType? = .event
    /// `EXT-X-MAP`: the init segment (ftyp + moov).
    public var mapURI: String?
    public var mapByteRange: HLSByteRange?
    public var segments: [HLSSegment] = []
    /// Writes `EXT-X-ENDLIST`.
    public var isEnded = false
    /// Writes `EXT-X-INDEPENDENT-SEGMENTS`: every segment starts with a keyframe.
    public var independentSegments = false

    public init(targetDuration: Int) {
        self.targetDuration = targetDuration
    }

    public func render() -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
        ]
        if let playlistType { lines.append("#EXT-X-PLAYLIST-TYPE:\(playlistType.rawValue)") }
        if independentSegments { lines.append("#EXT-X-INDEPENDENT-SEGMENTS") }
        if let mapURI {
            var map = "#EXT-X-MAP:URI=\"\(mapURI)\""
            if let mapByteRange { map += ",BYTERANGE=\"\(mapByteRange.attribute)\"" }
            lines.append(map)
        }
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            if let range = segment.byteRange { lines.append("#EXT-X-BYTERANGE:\(range.attribute)") }
            lines.append(segment.uri)
        }
        if isEnded { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The dynamic range of a variant's video (`VIDEO-RANGE`).
public enum HLSVideoRange: String, Sendable {
    case sdr = "SDR"
    case hlg = "HLG"
    case pq = "PQ"
}

public struct HLSResolution: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One `EXT-X-STREAM-INF` entry of a multivariant playlist.
public struct HLSVariant: Sendable, Equatable {
    /// The media playlist, relative to the multivariant playlist.
    public var uri: String
    /// Peak bit rate in bits per second.
    public var bandwidth: Int
    public var averageBandwidth: Int?
    /// RFC 6381 codec strings, video first.
    public var codecs: [String]
    /// Codecs a capable player may decode instead, each with its compatibility brand, such as "dvh1.08.06/db1p".
    public var supplementalCodecs: [String]
    public var resolution: HLSResolution?
    public var frameRate: Double?
    public var videoRange: HLSVideoRange?

    public init(uri: String, bandwidth: Int, averageBandwidth: Int? = nil, codecs: [String] = [],
                supplementalCodecs: [String] = [], resolution: HLSResolution? = nil,
                frameRate: Double? = nil, videoRange: HLSVideoRange? = nil) {
        self.uri = uri
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
        self.codecs = codecs
        self.supplementalCodecs = supplementalCodecs
        self.resolution = resolution
        self.frameRate = frameRate
        self.videoRange = videoRange
    }

    var tag: String {
        var attributes = ["BANDWIDTH=\(bandwidth)"]
        if let averageBandwidth { attributes.append("AVERAGE-BANDWIDTH=\(averageBandwidth)") }
        if let videoRange { attributes.append("VIDEO-RANGE=\(videoRange.rawValue)") }
        if !codecs.isEmpty { attributes.append("CODECS=\"\(codecs.joined(separator: ","))\"") }
        if !supplementalCodecs.isEmpty {
            attributes.append("SUPPLEMENTAL-CODECS=\"\(supplementalCodecs.joined(separator: ","))\"")
        }
        if let resolution { attributes.append("RESOLUTION=\(resolution.width)x\(resolution.height)") }
        if let frameRate { attributes.append(String(format: "FRAME-RATE=%.3f", frameRate)) }
        return "#EXT-X-STREAM-INF:" + attributes.joined(separator: ",")
    }
}

/// A multivariant playlist (RFC 8216 §4.3.4). AVPlayer reads it before loading any media to pick the
/// decoder and display mode, which is how HDR10, HLG and Dolby Vision reach the screen as such.
public struct HLSMultivariantPlaylist: Sendable, Equatable {
    public var variants: [HLSVariant]
    /// Writes `EXT-X-INDEPENDENT-SEGMENTS`: every segment of every variant starts with a keyframe.
    public var independentSegments = true

    public init(variants: [HLSVariant]) {
        self.variants = variants
    }

    public func render() -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        if independentSegments { lines.append("#EXT-X-INDEPENDENT-SEGMENTS") }
        for variant in variants {
            lines.append(variant.tag)
            lines.append(variant.uri)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
