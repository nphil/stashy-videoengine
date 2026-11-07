import Foundation

/// The tracks an fMP4 initialization segment (`ftyp` + `moov`) declares.
public struct InitSegment: Sendable, Equatable {
    public struct Track: Sendable, Equatable {
        /// Handler type, such as "vide" or "soun".
        public var handler: String
        /// Four-character code of the first sample entry, such as "hvc1", "hev1", "avc1", "mp4a" or "ec-3".
        public var sampleEntry: String

        public init(handler: String, sampleEntry: String) {
            self.handler = handler
            self.sampleEntry = sampleEntry
        }
    }

    public var tracks: [Track]

    public init(tracks: [Track]) {
        self.tracks = tracks
    }

    /// Parses the `moov` box at the top level of `data`; nil when there is none.
    public init?(data: Data) {
        guard let moov = BoxReader.children(data, from: 0, to: data.count).first(where: { $0.type == "moov" }) else { return nil }
        tracks = BoxReader.children(data, from: moov.start, to: moov.end)
            .filter { $0.type == "trak" }
            .compactMap { Self.track(in: data, trak: $0) }
    }

    /// Sample entry of the first video track: the first thing to check when AVPlayer shows a black picture.
    public var videoSampleEntry: String? {
        tracks.first { $0.handler == "vide" }?.sampleEntry
    }

    private static func track(in data: Data, trak: BoxReader.Child) -> Track? {
        guard let mdia = child("mdia", of: trak, in: data),
              let hdlr = child("hdlr", of: mdia, in: data),
              let stsd = path(["minf", "stbl", "stsd"], from: mdia, in: data) else { return nil }
        // hdlr: version/flags, pre_defined, then handler_type. stsd: version/flags, entry_count, then entries.
        let entry = BoxReader.children(data, from: stsd.start + 8, to: stsd.end).first
        return Track(handler: BoxReader.fourcc(data, hdlr.start + 8), sampleEntry: entry?.type ?? "")
    }

    private static func child(_ type: String, of box: BoxReader.Child, in data: Data) -> BoxReader.Child? {
        BoxReader.children(data, from: box.start, to: box.end).first { $0.type == type }
    }

    private static func path(_ types: [String], from box: BoxReader.Child, in data: Data) -> BoxReader.Child? {
        types.reduce(Optional(box)) { current, type in current.flatMap { child(type, of: $0, in: data) } }
    }
}
