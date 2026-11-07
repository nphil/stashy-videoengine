import Foundation

/// The tracks an fMP4 initialization segment (`ftyp` + `moov`) declares, and the HLS attributes they
/// imply. Reading them from the file the player will decode keeps the playlist from contradicting it.
public struct InitSegment: Sendable, Equatable {
    public struct Track: Sendable, Equatable {
        /// Handler type, such as "vide" or "soun".
        public var handler: String
        /// Four-character code of the first sample entry, such as "hvc1", "hev1", "avc1", "mp4a" or "ec-3".
        public var sampleEntry: String
        /// RFC 6381 codec string, such as "hvc1.2.4.L153.B0", "avc1.640028", "mp4a.40.2" or "dvh1.05.06".
        public var codec: String
        /// Coded size of a video track; 0 for other tracks.
        public var width: Int
        public var height: Int
        /// Transfer characteristics (ITU-T H.273) of the `colr` box: 16 is PQ, 18 is HLG. Nil without one.
        public var transferCharacteristics: Int?
        public var dolbyVision: DolbyVisionConfiguration?

        public init(handler: String, sampleEntry: String, codec: String? = nil, width: Int = 0, height: Int = 0,
                    transferCharacteristics: Int? = nil, dolbyVision: DolbyVisionConfiguration? = nil) {
            self.handler = handler
            self.sampleEntry = sampleEntry
            self.codec = codec ?? sampleEntry
            self.width = width
            self.height = height
            self.transferCharacteristics = transferCharacteristics
            self.dolbyVision = dolbyVision
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

    /// The `EXT-X-STREAM-INF` entry for this file.
    /// - Parameter transferFallback: The video's transfer characteristics (ITU-T H.273) from the bitstream,
    ///   used when the sample entry has no `colr` box.
    public func variant(uri: String, bandwidth: Int, averageBandwidth: Int? = nil, frameRate: Double? = nil,
                        transferFallback: Int? = nil) -> HLSVariant {
        let video = tracks.first { $0.handler == "vide" }
        var codecs: [String] = []
        for track in tracks where track.handler == "vide" || track.handler == "soun" {
            if !codecs.contains(track.codec) { codecs.append(track.codec) }
        }
        var variant = HLSVariant(uri: uri, bandwidth: bandwidth, averageBandwidth: averageBandwidth, codecs: codecs)
        guard let video else { return variant }
        if video.width > 0, video.height > 0 {
            variant.resolution = HLSResolution(width: video.width, height: video.height)
        }
        variant.frameRate = frameRate
        variant.videoRange = Self.videoRange(of: video, transferFallback: transferFallback)
        if let supplemental = Self.supplementalCodec(of: video) { variant.supplementalCodecs = [supplemental] }
        return variant
    }

    private static let dolbyVisionEntries: Set<String> = ["dvh1", "dvhe", "dva1", "dvav"]

    private static func videoRange(of video: Track, transferFallback: Int?) -> HLSVideoRange {
        if let dolbyVision = video.dolbyVision, dolbyVisionEntries.contains(video.sampleEntry) {
            // The range of what the decoder outputs without the Dolby Vision layer. Profile 5 has no
            // compatible base layer (ID 0) and is PQ-based.
            switch dolbyVision.compatibilityID {
            case 2: return .sdr
            case 4: return .hlg
            default: return .pq
            }
        }
        switch video.transferCharacteristics ?? transferFallback {
        case 16: return .pq
        case 18: return .hlg
        default: return .sdr
        }
    }

    /// The Dolby Vision reading of an HEVC track whose base layer is HDR10 or HLG (profile 8.1 or 8.4):
    /// players without Dolby Vision ignore it and play the base layer.
    private static func supplementalCodec(of video: Track) -> String? {
        guard let dolbyVision = video.dolbyVision, dolbyVision.profile == 8 else { return nil }
        let entry: String
        switch video.sampleEntry {
        case "hvc1": entry = "dvh1"
        case "hev1": entry = "dvhe"
        default: return nil
        }
        let brand: String
        switch dolbyVision.compatibilityID {
        case 1: brand = "db1p"
        case 4: brand = "db4h"
        default: return nil
        }
        return "\(entry).08.\(twoDigits(dolbyVision.level))/\(brand)"
    }

    // MARK: - Parsing

    private static func track(in data: Data, trak: BoxReader.Child) -> Track? {
        guard let mdia = child("mdia", of: trak, in: data),
              let hdlr = child("hdlr", of: mdia, in: data),
              let stsd = path(["minf", "stbl", "stsd"], from: mdia, in: data) else { return nil }
        // hdlr: version/flags, pre_defined, then handler_type. stsd: version/flags, entry_count, then entries.
        let handler = BoxReader.fourcc(data, hdlr.start + 8)
        guard let entry = BoxReader.children(data, from: stsd.start + 8, to: stsd.end).first else {
            return Track(handler: handler, sampleEntry: "")
        }
        switch handler {
        case "vide": return visualTrack(entry, in: data)
        case "soun": return audioTrack(entry, in: data)
        default: return Track(handler: handler, sampleEntry: entry.type)
        }
    }

    /// A VisualSampleEntry: 6 reserved bytes and the data reference index, 16 bytes of pre-defined and
    /// reserved fields, then width and height; its child boxes start after the 78-byte header.
    private static func visualTrack(_ entry: BoxReader.Child, in data: Data) -> Track {
        let children = BoxReader.children(data, from: entry.start + 78, to: entry.end)
        func find(_ types: Set<String>) -> BoxReader.Child? { children.first { types.contains($0.type) } }

        let dolbyVision = find(["dvcC", "dvvC", "dvwC"]).map { dolbyVisionConfiguration($0, in: data) }
        var codec = entry.type
        if dolbyVisionEntries.contains(entry.type), let dolbyVision {
            codec = "\(entry.type).\(twoDigits(dolbyVision.profile)).\(twoDigits(dolbyVision.level))"
        } else if let hvcC = find(["hvcC"]) {
            codec = hevcCodec(entry.type, hvcC, in: data)
        } else if let avcC = find(["avcC"]) {
            codec = entry.type + "." + [1, 2, 3].map { hex2(BoxReader.byte(data, avcC.start + $0)) }.joined()
        }

        var transfer: Int?
        if let colr = find(["colr"]) {
            let type = BoxReader.fourcc(data, colr.start)
            if type == "nclx" || type == "nclc" { transfer = Int(BoxReader.be16(data, colr.start + 6)) }
        }
        return Track(handler: "vide", sampleEntry: entry.type, codec: codec,
                     width: Int(BoxReader.be16(data, entry.start + 24)),
                     height: Int(BoxReader.be16(data, entry.start + 26)),
                     transferCharacteristics: transfer, dolbyVision: dolbyVision)
    }

    /// An AudioSampleEntry: its child boxes follow a 28-byte header, longer in the QuickTime versions 1 and 2.
    private static func audioTrack(_ entry: BoxReader.Child, in data: Data) -> Track {
        let headerLength: Int
        switch BoxReader.be16(data, entry.start + 8) {
        case 1: headerLength = 44
        case 2: headerLength = 64
        default: headerLength = 28
        }
        var codec = entry.type
        if entry.type == "mp4a" {
            let esds = BoxReader.children(data, from: entry.start + headerLength, to: entry.end)
                .first { $0.type == "esds" }
            codec = esds.map { mpeg4AudioCodec($0, in: data) } ?? "mp4a.40.2"
        }
        return Track(handler: "soun", sampleEntry: entry.type, codec: codec)
    }

    /// ISO/IEC 14496-15 Annex E: profile space and IDC, the compatibility flags bit-reversed in hex, tier and
    /// level, then the constraint bytes in hex without trailing zero bytes.
    private static func hevcCodec(_ entry: String, _ hvcC: BoxReader.Child, in data: Data) -> String {
        let first = BoxReader.byte(data, hvcC.start + 1)
        let space = ["", "A", "B", "C"][Int(first >> 6)]
        let tier = first & 0x20 != 0 ? "H" : "L"
        var flags = BoxReader.be32(data, hvcC.start + 2)
        var reversed: UInt32 = 0
        for _ in 0..<32 {
            reversed = reversed << 1 | flags & 1
            flags >>= 1
        }
        var constraints = (0..<6).map { BoxReader.byte(data, hvcC.start + 6 + $0) }
        while constraints.last == 0 { constraints.removeLast() }
        let parts = [entry, "\(space)\(first & 0x1F)", String(reversed, radix: 16, uppercase: true),
                     "\(tier)\(BoxReader.byte(data, hvcC.start + 12))"]
            + constraints.map { String($0, radix: 16, uppercase: true) }
        return parts.joined(separator: ".")
    }

    /// "mp4a.40.<audio object type>" from the `esds` descriptors; "mp4a.40.34" for MP3, as Apple lists it.
    private static func mpeg4AudioCodec(_ esds: BoxReader.Child, in data: Data) -> String {
        var objectType: UInt8 = 0x40
        var audioObjectType = 2
        // A full box header, then nested descriptors: tag, a size of up to four 7-bit groups, payload.
        var offset = esds.start + 4
        while offset < esds.end {
            let tag = BoxReader.byte(data, offset)
            var size = 0
            var cursor = offset + 1
            for _ in 0..<4 {
                let byte = BoxReader.byte(data, cursor)
                cursor += 1
                size = size << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            switch tag {
            case 0x03:
                // ES_Descriptor: ES_ID, flags, the optional fields the flags announce, then descriptors.
                let flags = BoxReader.byte(data, cursor + 2)
                var next = cursor + 3
                if flags & 0x80 != 0 { next += 2 }
                if flags & 0x40 != 0 { next += 1 + Int(BoxReader.byte(data, next)) }
                if flags & 0x20 != 0 { next += 2 }
                offset = next
            case 0x04:
                // DecoderConfigDescriptor: object type, 12 bytes of stream type and rates, then descriptors.
                objectType = BoxReader.byte(data, cursor)
                offset = cursor + 13
            case 0x05:
                // DecoderSpecificInfo, the AudioSpecificConfig: a 5-bit object type, 31 escaping to 6 more bits.
                let first = BoxReader.byte(data, cursor)
                audioObjectType = Int(first >> 3)
                if audioObjectType == 31 {
                    audioObjectType = 32 + (Int(first & 0x07) << 3 | Int(BoxReader.byte(data, cursor + 1) >> 5))
                }
                offset = esds.end
            default:
                offset = cursor + size
            }
        }
        switch objectType {
        case 0x40: return "mp4a.40.\(audioObjectType)"
        case 0x69, 0x6B: return "mp4a.40.34"
        default: return "mp4a." + String(objectType, radix: 16, uppercase: true)
        }
    }

    /// The Dolby Vision decoder configuration record: version, then profile (7 bits), level (6 bits),
    /// three layer flags, and the base-layer compatibility ID in the next byte's high nibble.
    private static func dolbyVisionConfiguration(_ box: BoxReader.Child, in data: Data) -> DolbyVisionConfiguration {
        let profileByte = BoxReader.byte(data, box.start + 2)
        let levelByte = BoxReader.byte(data, box.start + 3)
        return DolbyVisionConfiguration(
            profile: Int(profileByte >> 1),
            level: Int(profileByte & 1) << 5 | Int(levelByte >> 3),
            compatibilityID: Int(BoxReader.byte(data, box.start + 4) >> 4),
            hasRPU: levelByte & 0x04 != 0,
            hasEnhancementLayer: levelByte & 0x02 != 0,
            hasBaseLayer: levelByte & 0x01 != 0
        )
    }

    private static func child(_ type: String, of box: BoxReader.Child, in data: Data) -> BoxReader.Child? {
        BoxReader.children(data, from: box.start, to: box.end).first { $0.type == type }
    }

    private static func path(_ types: [String], from box: BoxReader.Child, in data: Data) -> BoxReader.Child? {
        types.reduce(Optional(box)) { current, type in current.flatMap { child(type, of: $0, in: data) } }
    }
}

/// A Dolby Vision decoder configuration record (`dvcC`, `dvvC` or `dvwC`).
public struct DolbyVisionConfiguration: Sendable, Equatable {
    public var profile: Int
    public var level: Int
    /// What the base layer is on its own: 1 HDR10, 2 SDR, 4 HLG, 6 Blu-ray HDR10, 0 none (profile 5).
    public var compatibilityID: Int
    public var hasRPU: Bool
    public var hasEnhancementLayer: Bool
    public var hasBaseLayer: Bool

    public init(profile: Int, level: Int, compatibilityID: Int, hasRPU: Bool = true,
                hasEnhancementLayer: Bool = false, hasBaseLayer: Bool = true) {
        self.profile = profile
        self.level = level
        self.compatibilityID = compatibilityID
        self.hasRPU = hasRPU
        self.hasEnhancementLayer = hasEnhancementLayer
        self.hasBaseLayer = hasBaseLayer
    }
}

private func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
}

private func hex2(_ byte: UInt8) -> String {
    (byte < 16 ? "0" : "") + String(byte, radix: 16, uppercase: true)
}
