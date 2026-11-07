import Foundation
import os

/// The HLS media playlist of a fragmented MP4 that is still being written: the init segment (`ftyp` +
/// `moov`), then one `moof` + `mdat` pair per keyframe group, each listed as a byte range of the one file.
/// AVPlayer will not play an open-ended progressive download of a growing file, but it streams a
/// playlist of bounded byte ranges.
///
/// The producer seals each segment once its bytes are on disk, with the duration it measured, so every
/// listed range is complete and nothing re-reads the file. The target duration is fixed up front:
/// RFC 8216 forbids changing it while the playlist grows, and AVPlayer paces its reloads by it.
public final class FragmentIndex: Sendable {
    private struct State: Sendable {
        var initLength: Int64 = 0
        var segments: [HLSSegment] = []
        /// End of the last sealed byte; the next segment starts here.
        var sealedEnd: Int64 = 0
        var isEnded = false
    }

    public let mediaName: String
    public let targetDuration: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameters:
    ///   - mediaName: The URI of the file, relative to the playlist.
    ///   - targetDuration: Whole seconds no segment exceeds.
    public init(mediaName: String, targetDuration: Int) {
        self.mediaName = mediaName
        self.targetDuration = max(1, targetDuration)
    }

    /// Records the init segment as the first `length` bytes of the file.
    public func setInitSegment(length: Int64) {
        state.withLock { state in
            guard state.initLength == 0, length > 0 else { return }
            state.initLength = length
            state.sealedEnd = length
        }
    }

    /// Lists the bytes after the previous segment, up to `endOffset`, as the next segment.
    public func seal(endOffset: Int64, duration: TimeInterval) {
        let uri = mediaName
        state.withLock { state in
            guard state.initLength > 0, !state.isEnded, endOffset > state.sealedEnd else { return }
            let range = HLSByteRange(length: endOffset - state.sealedEnd, offset: state.sealedEnd)
            state.segments.append(HLSSegment(duration: duration, uri: uri, byteRange: range))
            state.sealedEnd = endOffset
        }
    }

    /// Ends the playlist with `EXT-X-ENDLIST`: no segment follows.
    public func finish() {
        state.withLock { $0.isEnded = true }
    }

    public var segmentCount: Int { state.withLock { $0.segments.count } }

    /// The longest sealed segment, in seconds; RFC 8216 requires it to round to at most `targetDuration`.
    public var longestSegment: TimeInterval { state.withLock { $0.segments.map { $0.duration }.max() ?? 0 } }

    /// The current media playlist, or nil until the init segment and one segment are sealed.
    public func playlist() -> String? {
        let snapshot = state.withLock { $0 }
        guard snapshot.initLength > 0, !snapshot.segments.isEmpty else { return nil }
        var playlist = HLSMediaPlaylist(targetDuration: targetDuration)
        playlist.independentSegments = true
        playlist.mapURI = mediaName
        playlist.mapByteRange = HLSByteRange(length: snapshot.initLength, offset: 0)
        playlist.segments = snapshot.segments
        playlist.isEnded = snapshot.isEnded
        return playlist.render()
    }
}
