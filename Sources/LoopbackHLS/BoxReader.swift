import Foundation

/// Bounds-checked big-endian readers for ISO BMFF boxes. The input is a file that is still being
/// written, so a short or malformed box reads as zero or empty instead of trapping.
enum BoxReader {
    struct Child: Equatable {
        var type: String
        /// Payload range, after the size/type header.
        var start: Int
        var end: Int
    }

    static func byte(_ d: Data, _ i: Int) -> UInt8 {
        let b = d.startIndex + i
        return (i >= 0 && b < d.endIndex) ? d[b] : 0
    }

    static func be16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(byte(d, i)) << 8 | UInt16(byte(d, i + 1))
    }

    static func be32(_ d: Data, _ i: Int) -> UInt32 {
        let b = d.startIndex + i
        guard i >= 0, b + 4 <= d.endIndex else { return 0 }
        return UInt32(d[b]) << 24 | UInt32(d[b + 1]) << 16 | UInt32(d[b + 2]) << 8 | UInt32(d[b + 3])
    }

    static func be64(_ d: Data, _ i: Int) -> UInt64 {
        UInt64(be32(d, i)) << 32 | UInt64(be32(d, i + 4))
    }

    static func fourcc(_ d: Data, _ i: Int) -> String {
        let b = d.startIndex + i
        guard i >= 0, b + 4 <= d.endIndex else { return "" }
        return String(decoding: d[b..<b + 4], as: UTF8.self)
    }

    /// The boxes directly inside `d[from..<to]`, accepting 64-bit (`size == 1`) and to-end (`size == 0`) sizes.
    static func children(_ d: Data, from: Int, to: Int) -> [Child] {
        var out: [Child] = []
        var off = from
        while off + 8 <= to {
            let size32 = be32(d, off)
            let type = fourcc(d, off + 4)
            var size = Int(size32)
            var headerLength = 8
            if size32 == 1 {
                guard off + 16 <= to else { break }
                let size64 = be64(d, off + 8)
                guard size64 <= UInt64(Int.max) else { break }
                size = Int(size64)
                headerLength = 16
            } else if size32 == 0 {
                size = to - off
            }
            guard size >= headerLength, size <= to - off else { break }
            out.append(Child(type: type, start: off + headerLength, end: off + size))
            off += size
        }
        return out
    }
}
