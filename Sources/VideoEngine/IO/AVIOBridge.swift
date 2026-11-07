import Foundation
import Libavformat
import Libavutil
import os

/// Stop flag and stall deadline of one FFmpeg run. FFmpeg polls `shouldInterrupt` from the worker thread
/// through the interrupt callback; any thread may stop the run or move the deadline.
final class RunControl: Sendable {
    private struct State: Sendable {
        var stopped = false
        var deadline: DispatchTime
    }

    private let state: OSAllocatedUnfairLock<State>

    init(timeout: TimeInterval) {
        state = OSAllocatedUnfairLock(initialState: State(deadline: .now() + timeout))
    }

    func stop() { state.withLock { $0.stopped = true } }

    var isStopped: Bool { state.withLock { $0.stopped } }

    /// Moves the deadline to `seconds` from now.
    func extendDeadline(by seconds: TimeInterval) {
        let deadline = DispatchTime.now() + seconds
        state.withLock { $0.deadline = deadline }
    }

    var shouldInterrupt: Bool {
        let now = DispatchTime.now()
        return state.withLock { $0.stopped || now > $0.deadline }
    }
}

/// What the input callbacks reach through `opaque`. Confined to the worker thread.
private final class InputContext {
    let source: any ByteRangeSource
    let control: RunControl
    var position: Int64 = 0
    /// The first error the source threw, reported instead of FFmpeg's generic code.
    var error: (any Error)?

    init(source: any ByteRangeSource, control: RunControl) {
        self.source = source
        self.control = control
    }

    func record(_ error: any Error) -> Int32 {
        if self.error == nil { self.error = error }
        return error is CancellationError ? FF.averrorExit : FF.eio
    }
}

/// An opened demuxer reading from a `ByteRangeSource` through a custom AVIOContext. Confined to the worker
/// thread that opened it.
final class DemuxInput {
    let context: UnsafeMutablePointer<AVFormatContext>
    private let avio: UnsafeMutablePointer<AVIOContext>
    private let opaque: Unmanaged<InputContext>
    private var isOpen = true

    /// Opens the container. Throws the source's own error when it threw one, `CancellationError` when the
    /// run was stopped, `.timedOut` past the deadline, else `.openFailed`.
    init(source: any ByteRangeSource, control: RunControl, bufferSize: Int) throws {
        let input = InputContext(source: source, control: control)
        guard let buffer = av_malloc(bufferSize) else { throw VideoEngineError.outOfMemory }
        let opaque = Unmanaged.passRetained(input)
        guard let avio = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self), Int32(bufferSize), 0, opaque.toOpaque(),
            readPacket, nil, seekInput
        ) else {
            av_free(buffer)
            opaque.release()
            throw VideoEngineError.outOfMemory
        }
        var format = avformat_alloc_context()
        if let format {
            format.pointee.pb = avio
            format.pointee.flags |= FF.avfmtFlagCustomIO
            format.pointee.interrupt_callback.callback = interruptCallback
            format.pointee.interrupt_callback.opaque = opaque.toOpaque()
        }
        // On failure avformat_open_input frees the format context but never a caller-supplied AVIOContext.
        let result = avformat_open_input(&format, nil, nil, nil)
        guard result >= 0, let format else {
            let error = Self.failure(code: result, input: input, opening: true)
            freeAVIO(avio)
            opaque.release()
            throw error
        }
        self.context = format
        self.avio = avio
        self.opaque = opaque
    }

    deinit { close() }

    /// The error for a failed FFmpeg call on this input.
    func failure(code: Int32) -> any Error {
        Self.failure(code: code, input: opaque.takeUnretainedValue(), opening: false)
    }

    /// A read failure FFmpeg may have reported as the end of the file, since demuxers treat an AVIOContext
    /// error as EOF: the source's own error, or the error the AVIOContext recorded. Nil at a real EOF.
    var readError: (any Error)? {
        let input = opaque.takeUnretainedValue()
        if let error = input.error { return error }
        let code = avio.pointee.error
        return code < 0 ? Self.failure(code: code, input: input, opening: false) : nil
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        var format: UnsafeMutablePointer<AVFormatContext>? = context
        avformat_close_input(&format)
        freeAVIO(avio)
        opaque.release()
    }

    private static func failure(code: Int32, input: InputContext, opening: Bool) -> any Error {
        if let error = input.error { return error }
        if code == FF.averrorExit { return input.control.isStopped ? CancellationError() : VideoEngineError.timedOut }
        return opening
            ? VideoEngineError.openFailed(code: code, message: FF.errorString(code))
            : VideoEngineError.readFailed(code: code)
    }
}

/// What the output callback reaches through `opaque`. Confined to the worker thread.
private final class OutputContext {
    let descriptor: Int32
    let didWrite: (Int64) -> Void
    var written: Int64 = 0

    init(descriptor: Int32, didWrite: @escaping (Int64) -> Void) {
        self.descriptor = descriptor
        self.didWrite = didWrite
    }
}

/// A muxer writing into a file through a custom AVIOContext, reporting the running byte total after each
/// write. The file is created or truncated. Confined to the worker thread that created it.
final class MuxOutput {
    let context: UnsafeMutablePointer<AVFormatContext>
    private let avio: UnsafeMutablePointer<AVIOContext>
    private let opaque: Unmanaged<OutputContext>
    private var isOpen = true

    init(formatName: String, fileURL: URL, bufferSize: Int, didWrite: @escaping (Int64) -> Void) throws {
        let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VideoEngineError.writeFailed(code: -errno) }
        var format: UnsafeMutablePointer<AVFormatContext>?
        let result = avformat_alloc_output_context2(&format, nil, formatName, nil)
        guard result >= 0, let format else {
            Darwin.close(descriptor)
            throw VideoEngineError.ffmpeg(code: result, message: FF.errorString(result))
        }
        let buffer = av_malloc(bufferSize)
        let opaque = Unmanaged.passRetained(OutputContext(descriptor: descriptor, didWrite: didWrite))
        guard let buffer, let avio = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self), Int32(bufferSize), 1, opaque.toOpaque(),
            nil, writePacket, nil   // fragmented MP4 only appends, so the output needs no seek callback
        ) else {
            av_free(buffer)
            avformat_free_context(format)
            Darwin.close(descriptor)
            opaque.release()
            throw VideoEngineError.outOfMemory
        }
        format.pointee.pb = avio
        format.pointee.flags |= FF.avfmtFlagCustomIO
        self.context = format
        self.avio = avio
        self.opaque = opaque
    }

    deinit { close() }

    var bytesWritten: Int64 { opaque.takeUnretainedValue().written }

    func close() {
        guard isOpen else { return }
        isOpen = false
        avformat_free_context(context)
        freeAVIO(avio)
        Darwin.close(opaque.takeUnretainedValue().descriptor)
        opaque.release()
    }
}

/// Frees an AVIOContext and its buffer, which FFmpeg may have replaced since `avio_alloc_context`.
private func freeAVIO(_ avio: UnsafeMutablePointer<AVIOContext>) {
    av_free(avio.pointee.buffer)
    var context: UnsafeMutablePointer<AVIOContext>? = avio
    avio_context_free(&context)
}

// C trampolines: top-level and non-capturing, reaching their state only through `opaque`. They never throw;
// failures become negative FFmpeg codes and the source's error is kept on the context.

private func readPacket(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buffer, size > 0 else { return FF.einval }
    let input = Unmanaged<InputContext>.fromOpaque(opaque).takeUnretainedValue()
    // FFmpeg polls the interrupt callback in only a few places when the IO is custom, so reads check it too.
    if input.control.shouldInterrupt { return FF.averrorExit }
    do {
        let count = try input.source.read(at: input.position, into: UnsafeMutableRawBufferPointer(start: buffer, count: Int(size)))
        guard count > 0 else { return FF.averrorEOF }
        input.position += Int64(count)
        return Int32(count)
    } catch {
        return input.record(error)
    }
}

private func seekInput(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    guard let opaque else { return Int64(FF.einval) }
    let input = Unmanaged<InputContext>.fromOpaque(opaque).takeUnretainedValue()
    do {
        if whence & FF.avseekSize != 0 { return try input.source.length() ?? Int64(FF.enosys) }
        let target: Int64
        switch whence & ~FF.avseekForce {
        case Int32(SEEK_SET): target = offset
        case Int32(SEEK_CUR): target = input.position + offset
        case Int32(SEEK_END):
            guard let size = try input.source.length() else { return Int64(FF.enosys) }
            target = size + offset
        default: return Int64(FF.einval)
        }
        guard target >= 0 else { return Int64(FF.einval) }
        input.position = target
        return target
    } catch {
        return Int64(input.record(error))
    }
}

private func interruptCallback(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<InputContext>.fromOpaque(opaque).takeUnretainedValue().control.shouldInterrupt ? 1 : 0
}

private func writePacket(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buffer else { return FF.einval }
    let output = Unmanaged<OutputContext>.fromOpaque(opaque).takeUnretainedValue()
    var done = 0
    while done < Int(size) {
        let count = write(output.descriptor, buffer + done, Int(size) - done)
        if count < 0 {
            if errno == EINTR { continue }
            return -errno
        }
        done += count
    }
    output.written += Int64(done)
    output.didWrite(output.written)
    return Int32(done)
}
