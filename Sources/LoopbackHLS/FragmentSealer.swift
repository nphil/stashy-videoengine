import Foundation

/// Follows a fragmented MP4 byte by byte as the muxer writes it, and seals each `moof` + `mdat` pair
/// into a `FragmentIndex` as soon as its last byte is written, with the duration its `trun` boxes
/// declare. A segment is therefore listed one keyframe interval after it starts, and its duration is
/// the muxer's own, whatever fragmentation the muxer was asked for.
///
/// Confined to the thread that writes the file.
public final class FragmentSealer {
    private struct Box {
        var type: String
        var end: Int64
        /// `moov` and `moof` are parsed; everything else, `mdat` included, only passes through.
        var keepsPayload: Bool
    }

    private struct Track {
        var id: UInt32
        var timescale: UInt32
        var handler: String
        var defaultSampleDuration: UInt32 = 0
    }

    public let index: FragmentIndex
    /// The bytes before the first fragment (`ftyp` + `moov`), complete once `moov` is.
    public private(set) var initSegment = Data()
    public private(set) var sealedSegments = 0
    /// True once `moov` has closed: right after the header, or with the first fragment under `delay_moov`.
    public var hasInitSegment: Bool { initLength != nil }

    private var offset: Int64 = 0
    private var header = Data()
    private var current: Box?
    private var payload = Data()
    private var initLength: Int64?
    private var tracks: [Track] = []
    private var pendingDuration: TimeInterval?
    /// Set by a box whose size cannot be followed; no further segment is sealed.
    private var isLost = false

    public init(index: FragmentIndex) {
        self.index = index
    }

    /// Takes the next bytes of the file, in order, once they are written.
    public func append(_ bytes: UnsafeRawBufferPointer) {
        var cursor = 0
        while cursor < bytes.count, !isLost {
            let remaining = bytes.count - cursor
            let take: Int
            if let box = current {
                take = Int(min(Int64(remaining), box.end - offset))
            } else {
                take = min(remaining, (header.count < 8 ? 8 : 16) - header.count)
            }
            let slice = UnsafeRawBufferPointer(rebasing: bytes[cursor..<cursor + take])
            cursor += take
            offset += Int64(take)
            if initLength == nil { initSegment.append(contentsOf: slice) }

            if current == nil {
                header.append(contentsOf: slice)
                openBoxIfHeaderIsComplete()
            } else if current?.keepsPayload == true {
                payload.append(contentsOf: slice)
            }
            if let box = current, offset == box.end {
                current = nil
                close(box)
            }
        }
    }

    private func openBoxIfHeaderIsComplete() {
        guard header.count >= 8 else { return }
        let size32 = BoxReader.be32(header, 0)
        if size32 == 1, header.count < 16 { return }
        let headerLength = size32 == 1 ? 16 : 8
        let size = size32 == 1 ? BoxReader.be64(header, 8) : UInt64(size32)
        // Size 0 means "to the end of the file", which has no end to seal at.
        guard size >= UInt64(headerLength), size <= UInt64(Int64.max) - UInt64(offset) else {
            isLost = true
            return
        }
        let type = BoxReader.fourcc(header, 4)
        header.removeAll(keepingCapacity: true)
        payload.removeAll(keepingCapacity: true)
        current = Box(
            type: type, end: offset - Int64(headerLength) + Int64(size),
            keepsPayload: type == "moov" || type == "moof"
        )
    }

    private func close(_ box: Box) {
        switch box.type {
        case "moov":
            tracks = Self.tracks(inMovie: payload)
            initLength = box.end
            index.setInitSegment(length: box.end)
        case "moof":
            pendingDuration = duration(ofFragment: payload)
        case "mdat":
            guard let duration = pendingDuration else { return }
            pendingDuration = nil
            index.seal(endOffset: box.end, duration: duration)
            sealedSegments += 1
        default:
            break
        }
    }

    private static func tracks(inMovie moov: Data) -> [Track] {
        var tracks: [Track] = []
        var defaults: [UInt32: UInt32] = [:]
        for box in BoxReader.children(moov, from: 0, to: moov.count) {
            if box.type == "trak", let track = track(moov, box) { tracks.append(track) }
            guard box.type == "mvex" else { continue }
            for trex in BoxReader.children(moov, from: box.start, to: box.end) where trex.type == "trex" {
                defaults[BoxReader.be32(moov, trex.start + 4)] = BoxReader.be32(moov, trex.start + 12)
            }
        }
        for i in tracks.indices { tracks[i].defaultSampleDuration = defaults[tracks[i].id] ?? 0 }
        return tracks
    }

    private static func track(_ d: Data, _ trak: BoxReader.Child) -> Track? {
        let children = BoxReader.children(d, from: trak.start, to: trak.end)
        guard let tkhd = children.first(where: { $0.type == "tkhd" }),
              let mdia = children.first(where: { $0.type == "mdia" }) else { return nil }
        let media = BoxReader.children(d, from: mdia.start, to: mdia.end)
        guard let mdhd = media.first(where: { $0.type == "mdhd" }),
              let hdlr = media.first(where: { $0.type == "hdlr" }) else { return nil }
        // Version 1 widens the creation and modification times from 32 to 64 bits.
        let id = BoxReader.be32(d, tkhd.start + (BoxReader.byte(d, tkhd.start) == 1 ? 20 : 12))
        let timescale = BoxReader.be32(d, mdhd.start + (BoxReader.byte(d, mdhd.start) == 1 ? 20 : 12))
        guard timescale > 0 else { return nil }
        return Track(id: id, timescale: timescale, handler: BoxReader.fourcc(d, hdlr.start + 8))
    }

    /// The fragment's duration on the video track, or on its longest track when it has no video.
    private func duration(ofFragment moof: Data) -> TimeInterval {
        var durations: [UInt32: TimeInterval] = [:]
        for traf in BoxReader.children(moof, from: 0, to: moof.count) where traf.type == "traf" {
            let boxes = BoxReader.children(moof, from: traf.start, to: traf.end)
            guard let tfhd = boxes.first(where: { $0.type == "tfhd" }) else { continue }
            let id = BoxReader.be32(moof, tfhd.start + 4)
            guard let track = tracks.first(where: { $0.id == id }) else { continue }
            let fallback = Self.defaultDuration(moof, tfhd) ?? track.defaultSampleDuration
            let ticks = boxes.filter { $0.type == "trun" }.reduce(UInt64(0)) {
                $0 + Self.ticks(moof, $1, defaultDuration: fallback)
            }
            durations[id, default: 0] += Double(ticks) / Double(track.timescale)
        }
        let main = tracks.first(where: { $0.handler == "vide" }) ?? tracks.first
        if let main, let duration = durations[main.id] { return duration }
        return durations.values.max() ?? 0
    }

    /// `default_sample_duration` from a `tfhd`, when its flags say it is present.
    private static func defaultDuration(_ d: Data, _ tfhd: BoxReader.Child) -> UInt32? {
        let flags = BoxReader.be32(d, tfhd.start) & 0xFF_FFFF
        guard flags & 0x08 != 0 else { return nil }
        var field = tfhd.start + 8
        if flags & 0x01 != 0 { field += 8 }  // base_data_offset
        if flags & 0x02 != 0 { field += 4 }  // sample_description_index
        return BoxReader.be32(d, field)
    }

    /// The summed sample durations of one `trun`, in its track's timescale.
    private static func ticks(_ d: Data, _ trun: BoxReader.Child, defaultDuration: UInt32) -> UInt64 {
        let flags = BoxReader.be32(d, trun.start) & 0xFF_FFFF
        let count = Int(BoxReader.be32(d, trun.start + 4))
        guard flags & 0x100 != 0 else { return UInt64(count) * UInt64(defaultDuration) }
        var first = trun.start + 8
        if flags & 0x01 != 0 { first += 4 }  // data_offset
        if flags & 0x04 != 0 { first += 4 }  // first_sample_flags
        // Each sample's record holds duration, size, flags and composition offset, as the flags select.
        let stride = 4 * (flags & 0xF00).nonzeroBitCount
        let samples = min(count, max(0, trun.end - first) / stride)
        var total: UInt64 = 0
        for sample in 0..<samples { total += UInt64(BoxReader.be32(d, first + sample * stride)) }
        return total
    }
}
