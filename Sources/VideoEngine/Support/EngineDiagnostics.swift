import Foundation
import os

/// What the engine measured recently, for a support screen or a bug report: one `perf-*` line per
/// measured run. Each stage behind those lines is also an `os_signpost` interval (subsystem
/// "VideoEngine", category "stages") for Instruments.
public enum EngineDiagnostics {
    static let signposter = OSSignposter(subsystem: "VideoEngine", category: "stages")
    private static let capacity = 100
    private static let lines = OSAllocatedUnfairLock(initialState: [String]())

    /// The recent lines, oldest first, one per line.
    public static func report() -> String {
        lines.withLock { $0 }.joined(separator: "\n")
    }

    /// `ProcessInfo.thermalState` as the report spells it.
    static func thermalState(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func note(_ line: String) {
        lines.withLock { lines in
            if lines.count == capacity { lines.removeFirst() }
            lines.append(line)
        }
    }
}

extension EngineLogger {
    /// Logs a measurement and keeps it for `EngineDiagnostics.report()`.
    func measurement(_ tag: String, _ fields: [(String, String)]) {
        event(tag, fields)
        EngineDiagnostics.note(([tag] + fields.map { "\($0.0)=\($0.1)" }).joined(separator: " "))
    }
}

/// One timed stage: an `os_signpost` interval plus its duration in seconds. Confined to the thread that
/// began it.
struct StageTimer {
    private let name: StaticString
    private let interval: OSSignpostIntervalState
    private let start = DispatchTime.now()

    init(_ name: StaticString) {
        self.name = name
        interval = EngineDiagnostics.signposter.beginInterval(name, id: EngineDiagnostics.signposter.makeSignpostID())
    }

    func end() -> TimeInterval {
        EngineDiagnostics.signposter.endInterval(name, interval)
        return seconds(since: start)
    }
}

/// Marks a point in a run, such as its first sealed segment, and returns the seconds since the run began.
func milestone(_ name: StaticString, since start: DispatchTime) -> TimeInterval {
    EngineDiagnostics.signposter.emitEvent(name)
    return seconds(since: start)
}

func seconds(since start: DispatchTime) -> TimeInterval {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
}
