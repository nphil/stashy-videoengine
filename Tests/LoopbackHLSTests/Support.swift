import Foundation
import Network
import os
import Testing
@testable import LoopbackHLS

/// Minimal ISO BMFF writer for synthetic MP4 files.
enum MP4 {
    static func be16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func be64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    static func box(_ type: String, _ payload: Data) -> Data {
        be32(UInt32(8 + payload.count)) + Data(type.utf8) + payload
    }

    /// A box whose size is written in the 64-bit field.
    static func largeBox(_ type: String, _ payload: Data) -> Data {
        be32(1) + Data(type.utf8) + be64(UInt64(16 + payload.count)) + payload
    }

    static func fullBox(_ type: String, flags: UInt32 = 0, _ payload: Data) -> Data {
        box(type, be32(flags) + payload)
    }

    /// The 78 bytes of fixed VisualSampleEntry fields, with the coded size at offset 24.
    static func visualFields(width: UInt16 = 0, height: UInt16 = 0) -> Data {
        Data(count: 24) + be16(width) + be16(height) + Data(count: 50)
    }

    /// The 28 bytes of fixed AudioSampleEntry fields (version 0).
    static let audioFields = Data(count: 28)

    /// A track whose one sample entry holds `fields`, then the child boxes in `children`.
    static func trak(trackID: UInt32 = 1, timescale: UInt32 = 90_000, handler: String = "vide",
                     entry: String, fields: Data, children: Data = Data()) -> Data {
        let tkhd = box("tkhd", Data([0, 0, 0, 7]) + be32(0) + be32(0) + be32(trackID) + Data(count: 68))
        let mdhd = box("mdhd", Data(count: 4) + be32(0) + be32(0) + be32(timescale) + be32(0) + Data(count: 4))
        let hdlr = box("hdlr", Data(count: 8) + Data(handler.utf8) + Data(count: 13))
        let stsd = box("stsd", Data(count: 4) + be32(1) + box(entry, fields + children))
        return box("trak", tkhd + box("mdia", mdhd + hdlr + box("minf", box("stbl", stsd))))
    }

    /// `ftyp` + `moov` with the given tracks.
    static func initSegment(_ traks: Data...) -> Data {
        movie(traks: traks)
    }

    /// `ftyp` + `moov` with the given tracks and, unless `trex` is empty, their fragment defaults.
    static func movie(traks: [Data], trex: [Data] = []) -> Data {
        let mvex = trex.isEmpty ? Data() : box("mvex", trex.reduce(Data(), +))
        return box("ftyp", Data("iso5".utf8) + be32(512) + Data("iso6mp41".utf8))
            + box("moov", box("mvhd", Data(count: 100)) + traks.reduce(Data(), +) + mvex)
    }

    static func trex(trackID: UInt32, defaultDuration: UInt32) -> Data {
        fullBox("trex", be32(trackID) + be32(1) + be32(defaultDuration) + be32(0) + be32(0))
    }

    /// A `traf` with one `trun`: per-sample `durations` when given, otherwise `count` samples whose duration
    /// comes from `defaultDuration` in the `tfhd`, or from the `trex` when that is nil too.
    static func traf(trackID: UInt32, durations: [UInt32]? = nil, count: Int = 0, defaultDuration: UInt32? = nil) -> Data {
        var tfhdFlags: UInt32 = 0x02_0000  // default-base-is-moof
        var tfhd = be32(trackID)
        if let defaultDuration {
            tfhdFlags |= 0x08
            tfhd += be32(defaultDuration)
        }
        let trun: Data
        if let durations {
            // Data offset, then a duration and a size per sample.
            let samples = durations.reduce(Data()) { $0 + be32($1) + be32(100) }
            trun = fullBox("trun", flags: 0x301, be32(UInt32(durations.count)) + be32(0) + samples)
        } else {
            trun = fullBox("trun", flags: 0x200, be32(UInt32(count)) + Data(count: 4 * count))
        }
        return box("traf", fullBox("tfhd", flags: tfhdFlags, tfhd) + fullBox("tfdt", be32(0)) + trun)
    }

    /// A `moof` with the given track fragments, then its `mdat`.
    static func fragment(_ trafs: Data..., mediaBytes: Int) -> Data {
        box("moof", fullBox("mfhd", be32(1)) + trafs.reduce(Data(), +)) + box("mdat", Data(count: mediaBytes))
    }
}

/// A temporary file whose readable size and completion the test controls.
final class GrowingFile: Sendable {
    let url: URL
    let bytes: Data
    private let state: OSAllocatedUnfairLock<(available: Int64, complete: Bool)>

    init(_ bytes: Data, available: Int64, complete: Bool = false) throws {
        self.bytes = bytes
        url = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        state = OSAllocatedUnfairLock(initialState: (available: available, complete: complete))
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var available: Int64 { state.withLock { $0.available } }
    var isComplete: Bool { state.withLock { $0.complete } }

    func update(available: Int64, complete: Bool) {
        state.withLock { $0 = (available: available, complete: complete) }
    }

    func route(_ path: String) -> LoopbackRoute {
        LoopbackRoute(path: path, .growingFile(url, availableBytes: { self.available },
                                               isComplete: { self.isComplete }, contentType: "video/mp4"))
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    /// Lower-cased names.
    var headers: [String: String]
    var body: Data
}

/// A raw HTTP/1.1 client, so the tests see exactly what the server sends.
enum RawHTTP {
    private struct Connection: @unchecked Sendable { let nw: NWConnection }

    static func get(_ base: URL, _ path: String, range: String? = nil) async throws -> HTTPResponse {
        var request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let range { request += "Range: \(range)\r\n" }
        request += "\r\n"
        let port = try #require(base.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
        let nw = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        defer { nw.cancel() }
        let raw: Data = try await withCheckedThrowingContinuation { continuation in
            nw.start(queue: .global())
            nw.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
            receive(Connection(nw: nw), Data(), continuation)
        }
        return try parse(raw)
    }

    private static func receive(_ connection: Connection, _ received: Data,
                                _ continuation: CheckedContinuation<Data, Error>) {
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            var all = received
            if let data { all.append(data) }
            if isComplete {
                continuation.resume(returning: all)
            } else if let error {
                continuation.resume(throwing: error)
            } else {
                receive(connection, all, continuation)
            }
        }
    }

    private static func parse(_ raw: Data) throws -> HTTPResponse {
        let end = try #require(raw.range(of: Data("\r\n\r\n".utf8)))
        let lines = String(decoding: raw[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let status = try #require(lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) })
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return HTTPResponse(status: status, headers: headers, body: Data(raw[end.upperBound...]))
    }
}
