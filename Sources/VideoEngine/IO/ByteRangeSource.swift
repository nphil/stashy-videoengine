import Foundation
import os

/// Random-access bytes of one media file. Calls block, and the engine makes them only from its own
/// worker threads.
public protocol ByteRangeSource: Sendable {
    /// Host and file name for logs; never a query string or header value.
    var logName: String { get }
    /// Total size in bytes, or nil when the source cannot tell.
    func length() throws -> Int64?
    /// Copies bytes starting at `offset` into `buffer` and returns how many were copied. Returns 0 only at
    /// the true end of the file; a failed read throws.
    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    /// Stops the source for good: a blocked call returns promptly and every later call throws
    /// `CancellationError`.
    func cancel()
    /// Recent download rate over the network, counted only while bytes were being fetched; nil for a
    /// local file or before the first bytes.
    var bytesPerSecond: Double? { get }
}

extension ByteRangeSource {
    public var bytesPerSecond: Double? { nil }
}

public enum ByteRangeSources {
    /// A source for a `file://`, `http://` or `https://` URL. `headers` go on every HTTP request, which is
    /// where credentials belong instead of the query string.
    public static func make(
        for url: URL, headers: [String: String] = [:], readAheadBytes: Int = 4 << 20
    ) throws -> any ByteRangeSource {
        if url.isFileURL { return try FileRangeSource(fileURL: url) }
        switch url.scheme?.lowercased() {
        case "http", "https": return HTTPRangeSource(url: url, headers: headers, readAheadBytes: readAheadBytes)
        default: throw VideoEngineError.unsupportedSource("no reader for \(url.scheme ?? "a scheme-less") URLs")
        }
    }
}

/// Reads a local file with `pread`, so concurrent readers need no shared file position.
public final class FileRangeSource: ByteRangeSource {
    public let logName: String
    private let descriptor: Int32
    private let size: Int64
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    public init(fileURL: URL) throws {
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw VideoEngineError.openFailed(code: -errno, message: fileURL.lastPathComponent) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = -errno
            close(descriptor)
            throw VideoEngineError.openFailed(code: code, message: fileURL.lastPathComponent)
        }
        self.descriptor = descriptor
        self.size = Int64(info.st_size)
        self.logName = fileURL.lastPathComponent
    }

    deinit { close(descriptor) }

    public func length() throws -> Int64? {
        try checkCancelled()
        return size
    }

    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try checkCancelled()
        guard let base = buffer.baseAddress, buffer.count > 0, offset < size else { return 0 }
        while true {
            let count = pread(descriptor, base, buffer.count, off_t(offset))
            if count >= 0 { return count }
            if errno != EINTR { throw VideoEngineError.readFailed(code: -errno) }
        }
    }

    public func cancel() { cancelled.withLock { $0 = true } }

    private func checkCancelled() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }
}
