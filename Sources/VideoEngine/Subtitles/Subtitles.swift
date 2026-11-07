import Foundation
import Libavcodec
import Libavformat
import Libavutil
import LoopbackHLS
import os

/// A subtitle picture (PGS, VobSub, DVB) for the app to draw over the video. These never go into the MP4:
/// AVPlayer has no bitmap subtitle format for HLS.
public struct SubtitleBitmap: Sendable, Equatable {
    /// Movie time, as for `SubtitleCue`.
    public var start: TimeInterval
    public var end: TimeInterval
    /// Position and size on the subtitle canvas, normally the video's coded size.
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var canvasWidth: Int
    public var canvasHeight: Int
    /// Straight (not premultiplied) RGBA, `width * 4` bytes per row.
    public var rgba: Data

    public init(start: TimeInterval, end: TimeInterval, x: Int, y: Int, width: Int, height: Int,
                canvasWidth: Int, canvasHeight: Int, rgba: Data) {
        self.start = start
        self.end = end
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.rgba = rgba
    }
}

/// The bitmaps of one subtitle stream, filled while a run reads the source; the app asks for what shows at
/// the player's current movie time.
public final class SubtitleOverlayTrack: Sendable {
    private let store: OSAllocatedUnfairLock<[SubtitleBitmap]>

    public init(_ bitmaps: [SubtitleBitmap] = []) {
        store = OSAllocatedUnfairLock(initialState: bitmaps)
    }

    public func add(_ bitmap: SubtitleBitmap) {
        store.withLock { $0.append(bitmap) }
    }

    public func bitmaps(at movieTime: TimeInterval) -> [SubtitleBitmap] {
        store.withLock { list in list.filter { $0.start <= movieTime && movieTime < $0.end } }
    }
}

/// Everything a sidecar subtitle file holds, in movie time.
public struct SubtitleFileContents: Sendable, Equatable {
    public var cues: [SubtitleCue]
    public var bitmaps: [SubtitleBitmap]

    public init(cues: [SubtitleCue] = [], bitmaps: [SubtitleBitmap] = []) {
        self.cues = cues
        self.bitmaps = bitmaps
    }
}

public enum SubtitleFile {
    /// Reads every event of a downloaded sidecar file: .srt, .vtt, .ass, .ssa, .smi or .sup (PGS). Text comes
    /// back as WebVTT cues, pictures as bitmaps; `forcedOnly`
    /// keeps only the PGS pictures flagged forced.
    public static func read(fileURL: URL, forcedOnly: Bool = false) async throws -> SubtitleFileContents {
        let result = OSAllocatedUnfairLock<SubtitleFileContents?>(initialState: nil)
        let control = RunControl(timeout: .infinity)
        try await runBlocking(threadName: "subtitle-file", cancel: { control.stop() }) {
            let input = try openLocalInput(fileURL, control: control)
            defer { input.close() }
            let format = input.context
            guard let index = (0..<Int(format.pointee.nb_streams)).first(where: {
                format.pointee.streams[$0]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
            }), let stream = format.pointee.streams[index] else { throw VideoEngineError.noPlayableStreams }
            let decoder = try SubtitleDecoder(stream: stream, startTime: 0, forcedOnly: forcedOnly)
            var contents = SubtitleFileContents()
            let owner = try FFPacket()
            let packet = owner.pointer
            while true {
                let read = av_read_frame(format, packet)
                if read == FF.averrorEOF { break }
                if read < 0 { throw input.readError ?? input.failure(code: read) }
                if Int(packet.pointee.stream_index) == index {
                    let decoded = decoder.decode(packet)
                    contents.cues += decoded.cues
                    contents.bitmaps += decoded.bitmaps
                }
                av_packet_unref(packet)
            }
            contents.bitmaps += decoder.finish()
            let finished = contents
            result.withLock { $0 = finished }
        }
        return result.withLock { $0 } ?? SubtitleFileContents()
    }
}

/// Decodes one subtitle stream into WebVTT cues or bitmaps in movie time. Confined to the reading thread.
final class SubtitleDecoder {
    let isBitmap: Bool
    private let context: FFCodecContext
    private let timeBase: AVRational
    /// Container start time in seconds; movie time = stream time - start time.
    private let startTime: TimeInterval
    /// Pictures shown until the next event, as PGS and VobSub do not say when they end.
    private var showing: [SubtitleBitmap] = []

    init(stream: UnsafeMutablePointer<AVStream>, startTime: TimeInterval, forcedOnly: Bool = false) throws {
        let parameters: UnsafeMutablePointer<AVCodecParameters> = stream.pointee.codecpar
        let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw VideoEngineError.decoderUnavailable(codec: name)
        }
        isBitmap = codec.pointee.id != AV_CODEC_ID_NONE
            && (avcodec_descriptor_get(codec.pointee.id)?.pointee.props ?? 0) & FF.codecPropBitmapSubtitle != 0
        context = try FFCodecContext(codec: codec)
        var result = avcodec_parameters_to_context(context.pointer, parameters)
        guard result >= 0 else { throw VideoEngineError.failure("configure \(name) decoder", result) }
        // Without it the decoder leaves the subtitle's pts unset.
        context.pointer.pointee.pkt_timebase = stream.pointee.time_base
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        if forcedOnly { av_dict_set(&options, "forced_subs_only", "1", 0) }
        result = avcodec_open2(context.pointer, codec, &options)
        guard result >= 0 else { throw VideoEngineError.failure("open \(name) decoder", result) }
        timeBase = stream.pointee.time_base
        self.startTime = startTime
    }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>) -> (cues: [SubtitleCue], bitmaps: [SubtitleBitmap]) {
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        guard avcodec_decode_subtitle2(context.pointer, &subtitle, &got, packet) >= 0, got != 0 else { return ([], []) }
        defer { avsubtitle_free(&subtitle) }
        let base: TimeInterval
        if subtitle.pts != FF.noPTS {
            base = Double(subtitle.pts) / Double(FF.timeBase)
        } else if packet.pointee.pts != FF.noPTS {
            base = Double(packet.pointee.pts) * av_q2d(timeBase)
        } else {
            return ([], [])
        }
        let start = base + Double(subtitle.start_display_time) / 1000 - startTime
        var end: TimeInterval?
        if subtitle.end_display_time != 0, subtitle.end_display_time != UInt32.max {
            end = base + Double(subtitle.end_display_time) / 1000 - startTime
        } else if packet.pointee.duration > 0 {
            end = start + Double(packet.pointee.duration) * av_q2d(timeBase)
        }

        // Any new event replaces the pictures on screen.
        var closed = showing.map { bitmap -> SubtitleBitmap in
            var bitmap = bitmap
            bitmap.end = max(bitmap.start, start)
            return bitmap
        }
        showing.removeAll()
        var cues: [SubtitleCue] = []
        for i in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[i]?.pointee else { continue }
            if rect.type == SUBTITLE_BITMAP {
                guard var bitmap = Self.bitmap(rect, canvas: (Int(context.pointer.pointee.width), Int(context.pointer.pointee.height))) else { continue }
                bitmap.start = start
                if let end {
                    bitmap.end = end
                    closed.append(bitmap)
                } else {
                    showing.append(bitmap)
                }
            } else if let line = rect.ass.map({ String(cString: $0) }) ?? rect.text.map({ String(cString: $0) }) {
                let text = rect.type == SUBTITLE_ASS ? Self.webVTTText(fromASS: line) : WebVTT.escape(line)
                if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end ?? start + 5, text: text)) }
            }
        }
        return (cues, closed)
    }

    /// Pictures still on screen when the stream ends, shown for 5 s more.
    func finish() -> [SubtitleBitmap] {
        defer { showing.removeAll() }
        return showing.map { bitmap in
            var bitmap = bitmap
            bitmap.end = bitmap.start + 5
            return bitmap
        }
    }

    /// Palette pictures to RGBA. The palette holds 32-bit ARGB values in native byte order.
    private static func bitmap(_ rect: AVSubtitleRect, canvas: (Int, Int)) -> SubtitleBitmap? {
        let width = Int(rect.w)
        let height = Int(rect.h)
        guard width > 0, height > 0, let pixels = rect.data.0, let palette = rect.data.1 else { return nil }
        let stride = Int(rect.linesize.0)
        let colours = UnsafeRawPointer(palette).assumingMemoryBound(to: UInt32.self)
        let count = Int(max(rect.nb_colors, 0))
        var rgba = Data(count: width * height * 4)
        // Annotated: Xcode 26's type checker finds the untyped closure ambiguous between Data's overloads.
        rgba.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Void in
            for row in 0..<height {
                for column in 0..<width {
                    let index = Int(pixels[row * stride + column])
                    let argb = index < count ? colours[index] : 0
                    let offset = (row * width + column) * 4
                    out[offset] = UInt8(truncatingIfNeeded: argb >> 16)
                    out[offset + 1] = UInt8(truncatingIfNeeded: argb >> 8)
                    out[offset + 2] = UInt8(truncatingIfNeeded: argb)
                    out[offset + 3] = UInt8(truncatingIfNeeded: argb >> 24)
                }
            }
        }
        return SubtitleBitmap(
            start: 0, end: 0, x: Int(rect.x), y: Int(rect.y), width: width, height: height,
            canvasWidth: canvas.0 > 0 ? canvas.0 : 1920, canvasHeight: canvas.1 > 0 ? canvas.1 : 1080, rgba: rgba
        )
    }

    /// The text of one ASS event line from FFmpeg ("ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,
    /// Effect,Text") as WebVTT: italic, bold and underline become tags, line breaks stay, drawings and
    /// every other override are dropped.
    static func webVTTText(fromASS line: String) -> String {
        let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let body = fields.count == 9 ? Substring(fields[8]) : Substring(line)
        var output = ""
        var open: [String] = []
        var drawing = false

        func set(_ tag: String, _ on: Bool) {
            if on {
                guard !open.contains(tag) else { return }
                open.append(tag)
                output += "<\(tag)>"
            } else if let position = open.lastIndex(of: tag) {
                // WebVTT tags must nest: close the ones opened later, then reopen them.
                let later = open[(position + 1)...]
                for inner in later.reversed() { output += "</\(inner)>" }
                output += "</\(tag)>"
                for inner in later { output += "<\(inner)>" }
                open.remove(at: position)
            }
        }

        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "{", let close = body[index...].firstIndex(of: "}") {
                for code in body[body.index(after: index)..<close].split(separator: "\\") {
                    switch code {
                    case "i1", "i": set("i", true)
                    case "i0": set("i", false)
                    case "b1", "b": set("b", true)
                    case "b0": set("b", false)
                    case "u1", "u": set("u", true)
                    case "u0": set("u", false)
                    default:
                        if code.first == "p", let level = Int(code.dropFirst()) { drawing = level > 0 }
                    }
                }
                index = body.index(after: close)
                continue
            }
            let next = body.index(after: index)
            if character == "\\", next < body.endIndex, "Nnh".contains(body[next]) {
                if !drawing { output += body[next] == "h" ? " " : "\n" }
                index = body.index(after: next)
                continue
            }
            if !drawing { output += WebVTT.escape(String(character)) }
            index = next
        }
        for tag in open.reversed() { output += "</\(tag)>" }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A subtitle a remux run offers: one of the source's streams, or a sidecar's text.
public struct RemuxSubtitle: Sendable {
    /// The source's stream index; nil for a sidecar.
    public var streamIndex: Int?
    /// Unique within the run; AVPlayer lists a WebVTT rendition under this name.
    public var name: String
    /// BCP-47, "und" when unknown.
    public var language: String
    public var isDefault: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// Text, served as a WebVTT rendition of the multivariant playlist.
    public var webVTT: SubtitleTrack?
    /// Pictures, for the app to draw over the video.
    public var overlay: SubtitleOverlayTrack?

    public init(streamIndex: Int?, name: String, language: String, isDefault: Bool = false, isForced: Bool = false,
                isHearingImpaired: Bool = false, webVTT: SubtitleTrack? = nil, overlay: SubtitleOverlayTrack? = nil) {
        self.streamIndex = streamIndex
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.webVTT = webVTT
        self.overlay = overlay
    }
}

/// Text cues from a sidecar file, offered as a WebVTT rendition next to the source's own subtitles.
public struct SidecarSubtitles: Sendable, Equatable {
    public var name: String
    /// BCP-47 or ISO 639-2, such as "en" or "eng".
    public var language: String
    public var isDefault: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    public var cues: [SubtitleCue]

    public init(name: String, language: String, isDefault: Bool = false, isForced: Bool = false,
                isHearingImpaired: Bool = false, cues: [SubtitleCue]) {
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.cues = cues
    }
}

enum SubtitleLanguage {
    /// The two-letter code where one exists ("eng" becomes "en"), as HLS wants BCP-47.
    static func tag(_ code: String?) -> String {
        guard let code, !code.isEmpty, code != "und" else { return "und" }
        return Locale.LanguageCode(code).identifier(.alpha2) ?? code
    }

    static func displayName(_ tag: String) -> String? {
        tag == "und" ? nil : Locale(identifier: "en").localizedString(forLanguageCode: tag)
    }
}
