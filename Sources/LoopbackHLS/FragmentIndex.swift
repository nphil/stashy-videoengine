import Foundation
import os

/// Turns a growing fragmented MP4 file (init = `ftyp` + `moov`, then one `moof` + `mdat` per keyframe
/// group) into an HLS byte-range media playlist. AVPlayer will not play an open-ended progressive
/// download of a file that is still growing, but it streams a playlist of bounded byte ranges.
///
/// Every `moof` starts at a keyframe, so each fragment is an independent segment. A fragment is listed
/// once the next `moof` exists, so its length and duration are final and every listed range is fully
/// written. Re-scanning is cheap: only top-level box headers and the small `moov`/`moof` boxes are read.
public final class FragmentIndex: Sendable {
    private struct Fragment: Sendable {
        var offset: Int64
        /// The video track's `tfdt` baseMediaDecodeTime.
        var time: UInt64
    }

    private struct ScanState: Sendable {
        var scanOffset: Int64 = 0
        /// End of `moov` = start of the first fragment.
        var initLength: Int64 = -1
        var videoTrackID: UInt32 = 0
        var timescale: UInt32 = 0
        var fragments: [Fragment] = []
    }

    private let fileURL: URL
    private let available: @Sendable () -> Int64
    private let isComplete: @Sendable () -> Bool
    /// Ends the final segment; the earlier ones end at the next fragment's `tfdt`.
    private let totalDuration: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: ScanState())

    public init(fileURL: URL,
                available: @escaping @Sendable () -> Int64,
                isComplete: @escaping @Sendable () -> Bool,
                totalDuration: TimeInterval) {
        self.fileURL = fileURL
        self.available = available
        self.isComplete = isComplete
        self.totalDuration = totalDuration
    }

    /// The current media playlist, or nil until the init segment and one complete fragment exist.
    public func playlist(mediaName: String) -> String? {
        // Completion is read before the size: the producer records its final size before it reports
        // completion, so a `true` here guarantees the size read next is final.
        let complete = self.isComplete()
        let size = self.available()
        return state.withLock { state in
            Self.scan(&state, fileURL: fileURL, available: size)
            return Self.render(state, mediaName: mediaName, available: size,
                               complete: complete, totalDuration: totalDuration)
        }
    }

    // MARK: - Top-level box walk

    private static func scan(_ state: inout ScanState, fileURL: URL, available: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        func read(_ offset: Int64, _ count: Int) -> Data? {
            guard offset >= 0, count > 0, offset + Int64(count) <= available else { return nil }
            do {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: count)
            } catch {
                return nil
            }
        }

        while true {
            guard let header = read(state.scanOffset, 16) ?? read(state.scanOffset, 8),
                  header.count >= 8 else { return }
            let size32 = BoxReader.be32(header, 0)
            var size = Int64(size32)
            var headerLength: Int64 = 8
            if size32 == 1 {
                guard header.count >= 16 else { return }
                let size64 = BoxReader.be64(header, 8)
                guard size64 <= UInt64(Int64.max) else { return }
                size = Int64(size64)
                headerLength = 16
            } else if size32 == 0 {
                return   // runs to the end of the file, which is still growing
            }
            guard size >= headerLength else { return }
            let boxEnd = state.scanOffset + size
            // The whole box must be present: for a growing `mdat` this waits until it is complete,
            // so the next header read is valid.
            guard boxEnd <= available else { return }

            switch BoxReader.fourcc(header, 4) {
            case "moov":
                guard size <= Int64(Int.max), let box = read(state.scanOffset, Int(size)) else { return }
                parseMoov(box, into: &state)
                state.initLength = boxEnd
            case "moof":
                guard size <= Int64(Int.max), let box = read(state.scanOffset, Int(size)) else { return }
                let time = videoTime(inMoof: box, trackID: state.videoTrackID)
                    ?? state.fragments.last?.time ?? 0
                state.fragments.append(Fragment(offset: state.scanOffset, time: time))
            default:
                break   // ftyp, mdat, free, styp, sidx
            }
            state.scanOffset = boxEnd
        }
    }

    /// The video track's id and media timescale.
    private static func parseMoov(_ d: Data, into state: inout ScanState) {
        for trak in BoxReader.children(d, from: 8, to: d.count) where trak.type == "trak" {
            var trackID: UInt32 = 0
            var handler = ""
            var timescale: UInt32 = 0
            for child in BoxReader.children(d, from: trak.start, to: trak.end) {
                switch child.type {
                case "tkhd":
                    let version = BoxReader.byte(d, child.start)
                    trackID = BoxReader.be32(d, child.start + (version == 1 ? 20 : 12))
                case "mdia":
                    for m in BoxReader.children(d, from: child.start, to: child.end) {
                        switch m.type {
                        case "hdlr":
                            handler = BoxReader.fourcc(d, m.start + 8)
                        case "mdhd":
                            let version = BoxReader.byte(d, m.start)
                            timescale = BoxReader.be32(d, m.start + (version == 1 ? 20 : 12))
                        default:
                            break
                        }
                    }
                default:
                    break
                }
            }
            if handler == "vide" {
                state.videoTrackID = trackID
                state.timescale = timescale
                return
            }
        }
    }

    /// The video track's `tfdt` in a `moof`, if present.
    private static func videoTime(inMoof d: Data, trackID: UInt32) -> UInt64? {
        for traf in BoxReader.children(d, from: 8, to: d.count) where traf.type == "traf" {
            var id: UInt32 = 0
            var decodeTime: UInt64?
            for child in BoxReader.children(d, from: traf.start, to: traf.end) {
                switch child.type {
                case "tfhd":
                    id = BoxReader.be32(d, child.start + 4)
                case "tfdt":
                    let version = BoxReader.byte(d, child.start)
                    decodeTime = version == 1
                        ? BoxReader.be64(d, child.start + 4)
                        : UInt64(BoxReader.be32(d, child.start + 4))
                default:
                    break
                }
            }
            if id == trackID, let decodeTime { return decodeTime }
        }
        return nil
    }

    // MARK: - Playlist

    private static func render(_ state: ScanState, mediaName: String, available: Int64,
                               complete: Bool, totalDuration: TimeInterval) -> String? {
        guard state.initLength > 0, state.timescale > 0, !state.fragments.isEmpty else { return nil }
        let fragments = state.fragments
        let timescale = Double(state.timescale)
        // The last fragment is final only once production is complete; its end is then the file end.
        let listable = complete ? fragments.count : fragments.count - 1
        guard listable >= 1 else { return nil }

        var segments: [HLSSegment] = []
        var lastDuration = 0.0
        for i in 0..<listable {
            let start = fragments[i].offset
            let end = i + 1 < fragments.count ? fragments[i + 1].offset : available
            guard end > start else { continue }
            var duration = i + 1 < fragments.count
                ? Double(fragments[i + 1].time &- fragments[i].time) / timescale
                : totalDuration - Double(fragments[i].time) / timescale
            if !(duration > 0) { duration = lastDuration > 0 ? lastDuration : 2 }
            lastDuration = duration
            segments.append(HLSSegment(duration: duration, uri: mediaName,
                                       byteRange: HLSByteRange(length: end - start, offset: start)))
        }
        guard let longest = segments.map(\.duration).max() else { return nil }

        var playlist = HLSMediaPlaylist(targetDuration: max(1, Int(longest.rounded(.up))))
        playlist.mapURI = mediaName
        playlist.mapByteRange = HLSByteRange(length: state.initLength, offset: 0)
        playlist.segments = segments
        playlist.isEnded = complete
        return playlist.render()
    }
}
