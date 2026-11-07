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
