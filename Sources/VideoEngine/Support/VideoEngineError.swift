import Foundation

/// Why an engine operation failed. A user cancel surfaces as Swift's `CancellationError` instead.
public enum VideoEngineError: Error, Sendable, Equatable, LocalizedError {
    /// The server refused the request (`status` set) or could not be reached (`status` nil).
    case sourceUnreachable(status: Int?)
    /// The source cannot be read as a seekable byte range, for example a server that ignores `Range`.
    case unsupportedSource(String)
    case openFailed(code: Int32, message: String)
    case noPlayableStreams
    case headerFailed(code: Int32, message: String)
    /// Reading the source failed part-way; never reported as the end of the file.
    case readFailed(code: Int32)
    /// Writing the output failed; code -28 means the disk is full.
    case writeFailed(code: Int32)
    case decoderUnavailable(codec: String)
    case encoderUnavailable(name: String)
    case audioNotCopyable(codec: String)
    case timedOut
    case serverBindFailed
    case ffmpeg(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .sourceUnreachable(let status?): "The video server answered with HTTP \(status)."
        case .sourceUnreachable(nil): "The video server could not be reached."
        case .unsupportedSource(let reason): "The video source is not supported: \(reason)."
        case .openFailed(_, let message): "The video could not be opened: \(message)."
        case .noPlayableStreams: "The video has no playable audio or video."
        case .headerFailed(_, let message): "The video stream could not be started: \(message)."
        case .readFailed(let code): "Reading the video failed: \(FF.errorString(code))."
        case .writeFailed(FF.enospc): "The device is out of storage space."
        case .writeFailed(let code): "Writing the video failed: \(FF.errorString(code))."
        case .decoderUnavailable(let codec): "No decoder is available for \(codec)."
        case .encoderUnavailable(let name): "The \(name) encoder is not available."
        case .audioNotCopyable(let codec): "The \(codec) audio cannot be copied into MP4."
        case .timedOut: "The video stopped responding."
        case .serverBindFailed: "The local playback server could not start."
        case .ffmpeg(_, let message): "FFmpeg failed: \(message)."
        }
    }
}
