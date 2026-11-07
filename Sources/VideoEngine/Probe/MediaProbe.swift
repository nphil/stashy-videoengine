import Foundation
import Libavformat

public enum ProbeDepth: Sendable {
    /// Opens the container and reads stream info only when the header leaves the video pixel format unknown.
    case quick
    /// Always reads stream info, which decodes a few packets per stream.
    case full
}

public enum MediaProbe {
    /// Reads the container and stream details of `source`. Cancelling the task cancels the source.
    public static func probe(
        _ source: any ByteRangeSource, depth: ProbeDepth = .quick, timeout: TimeInterval = 8,
        logger: EngineLogger = .silent
    ) async throws -> MediaInfo {
        let control = RunControl(timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try run(source, depth: depth, control: control, logger: logger) })
                }
            }
        } onCancel: {
            control.stop()
            source.cancel()
        }
    }

    /// Probes a `file://`, `http://` or `https://` URL. Each read is one request, sized to what FFmpeg asks for.
    public static func probe(
        url: URL, headers: [String: String] = [:], depth: ProbeDepth = .quick, timeout: TimeInterval = 8,
        logger: EngineLogger = .silent
    ) async throws -> MediaInfo {
        let source = try ByteRangeSources.make(for: url, headers: headers, readAheadBytes: 0)
        return try await probe(source, depth: depth, timeout: timeout, logger: logger)
    }

    private static func run(
        _ source: any ByteRangeSource, depth: ProbeDepth, control: RunControl, logger: EngineLogger
    ) throws -> MediaInfo {
        let started = DispatchTime.now()
        do {
            let input = try DemuxInput(source: source, control: control, bufferSize: 64 << 10)
            defer { input.close() }
            var info = MediaInfo(format: input.context)
            // MP4 and Matroska headers usually carry the pixel format; reading stream info costs extra requests.
            if depth == .full || info.video.first?.pixelFormat == nil {
                let result = avformat_find_stream_info(input.context, nil)
                if result < 0, control.isStopped { throw CancellationError() }
                info = MediaInfo(format: input.context)
            }
            logger.event("probe", [
                ("source", source.logName), ("container", info.container),
                ("video", info.video.first.map { "\($0.codec)/\($0.pixelFormat ?? "?")/\($0.width)x\($0.height)" } ?? "none"),
                ("audio", info.audio.map(\.codec).joined(separator: ",")),
                ("ms", String(milliseconds(since: started))),
            ])
            return info
        } catch {
            logger.event("probe-fail", [("source", source.logName), ("error", String(describing: error)),
                                        ("ms", String(milliseconds(since: started)))])
            throw error
        }
    }
}

func milliseconds(since start: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}
