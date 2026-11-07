import Libavutil

/// FFmpeg values defined by function-like or expression macros, which the Swift importer does not
/// surface. A test checks the error codes against `av_strerror`, so drift after an FFmpeg bump fails CI.
enum FF {
    /// AVERROR_EOF, -MKTAG('E','O','F',' ').
    static let averrorEOF: Int32 = -541_478_725
    /// AVERROR_EXIT, -MKTAG('E','X','I','T'): the interrupt callback asked FFmpeg to stop.
    static let averrorExit: Int32 = -1_414_092_869
    /// AVERROR(errno) values with Darwin errno numbers.
    static let eagain: Int32 = -35
    static let eio: Int32 = -5
    static let enospc: Int32 = -28
    static let enomem: Int32 = -12
    static let einval: Int32 = -22
    static let enosys: Int32 = -78

    static let avseekSize: Int32 = 0x10000
    static let avseekForce: Int32 = 0x20000
    static let seekBackward: Int32 = 1
    static let avfmtFlagCustomIO: Int32 = 0x0080
    static let avfmtGlobalHeader: Int32 = 0x0040
    static let codecFlagGlobalHeader: Int32 = 1 << 22
    static let avioFlagWrite: Int32 = 2
    static let noPTS: Int64 = .min
    static let swsBilinear: Int32 = 2
    static let packetFlagKey: Int32 = 1
    static let indexKeyframe: Int32 = 1

    static let dispositionDefault: Int32 = 1 << 0
    static let dispositionForced: Int32 = 1 << 6
    static let dispositionHearingImpaired: Int32 = 1 << 7
    static let dispositionVisualImpaired: Int32 = 1 << 8
    static let dispositionAttachedPicture: Int32 = 1 << 10
    static let dispositionCaptions: Int32 = 1 << 16
    static let dispositionDescriptions: Int32 = 1 << 17
    static let codecPropBitmapSubtitle: Int32 = 1 << 16
    static let timeBase: Int64 = 1_000_000

    /// The `av_strerror` text for an FFmpeg error code.
    static func errorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, 128)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A C string as a Swift string, nil for NULL or empty.
    static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer, pointer.pointee != 0 else { return nil }
        return String(cString: pointer)
    }

    /// A codec tag (little-endian FourCC) as text, such as "hvc1"; nil for 0.
    static func fourCC(_ tag: UInt32) -> String? {
        guard tag != 0 else { return nil }
        let bytes = [tag, tag >> 8, tag >> 16, tag >> 24].map { UInt8($0 & 0xff) }
        return String(decoding: bytes.map { (0x20...0x7e).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }

    /// A little-endian codec tag from four ASCII characters.
    static func tag(_ fourCC: String) -> UInt32 {
        var tag: UInt32 = 0
        for (i, byte) in fourCC.utf8.prefix(4).enumerated() { tag |= UInt32(byte) << (8 * UInt32(i)) }
        return tag
    }
}
