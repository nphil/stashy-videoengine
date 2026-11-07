import Foundation
import os

/// One subtitle cue. Times are movie time: seconds from the start of the source, as the media server and
/// the player's UI count them.
public struct SubtitleCue: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    /// WebVTT cue text: `<i>`, `<b>` and `<u>` markup, everything else escaped.
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum WebVTT {
    /// A WebVTT document whose cue times are shifted by `-origin` onto the media file's timeline, which
    /// starts at 0, so the timestamp map pins local 0 to MPEG-TS 0.
    public static func document(_ cues: [SubtitleCue], origin: TimeInterval = 0) -> String {
        var text = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n"
        for cue in cues {
            text += "\n\(timestamp(cue.start - origin)) --> \(timestamp(cue.end - origin))\n\(cue.text)\n"
        }
        return text
    }

    /// `hh:mm:ss.mmm`; negative times clamp to zero.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        let (hours, rest) = milliseconds.quotientAndRemainder(dividingBy: 3_600_000)
        let (minutes, rest2) = rest.quotientAndRemainder(dividingBy: 60_000)
        let (secs, millis) = rest2.quotientAndRemainder(dividingBy: 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    /// Escapes plain text for a cue payload.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// The cues of one subtitle rendition, served as fixed WebVTT slots that are independent of the video's
/// segments. A slot holds every cue overlapping it, so a cue repeats in each slot it touches. The
/// playlist grows with the video's and ends when it does; a slot is listed once the producer has read
/// `holdback` seconds past its end, so a listed slot never gains cues.
public final class SubtitleTrack: Sendable {
    public let slotDuration: Int
    public let targetDuration: Int
    private let holdback: TimeInterval

    private struct State {
        var cues: [SubtitleCue] = []
        /// Served time = movie time - origin; nil until the media file's timeline is fixed.
        var origin: TimeInterval?
        var readThrough: TimeInterval = 0
        /// Served length of the media once the producer is done.
        var finalDuration: TimeInterval?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameter targetDuration: the video playlist's, so both declare the same value.
    public init(targetDuration: Int, slotDuration: Int = 10, holdback: TimeInterval = 5) {
        self.targetDuration = max(targetDuration, slotDuration)
        self.slotDuration = slotDuration
        self.holdback = holdback
    }

    public func add(_ cue: SubtitleCue) {
        state.withLock { $0.cues.append(cue) }
    }

    public func add(contentsOf cues: [SubtitleCue]) {
        state.withLock { $0.cues.append(contentsOf: cues) }
    }

    public func setOrigin(_ origin: TimeInterval) {
        state.withLock { $0.origin = origin }
    }

    /// The producer has read the source up to `served` seconds of the media file's timeline.
    public func readThrough(_ served: TimeInterval) {
        state.withLock { $0.readThrough = max($0.readThrough, served) }
    }

    /// The media file is complete and `served` seconds long.
    public func finish(duration served: TimeInterval) {
        state.withLock { $0.finalDuration = served }
    }

    /// The media playlist naming each listed slot `<prefix><k>.vtt`.
    public func playlist(slotPrefix: String) -> String {
        let (count, duration) = state.withLock { s -> (Int, TimeInterval?) in (listedSlots(s), s.finalDuration) }
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(targetDuration)", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:EVENT",
        ]
        for k in 0..<count {
            var length = TimeInterval(slotDuration)
            if let duration, k == count - 1 { length = max(0.001, duration - TimeInterval(k * slotDuration)) }
            lines.append(String(format: "#EXTINF:%.3f,", length))
            lines.append("\(slotPrefix)\(k).vtt")
        }
        if duration != nil { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Slot `k` as a WebVTT document, or nil while it is not listed.
    public func slot(_ k: Int) -> String? {
        state.withLock { s -> String? in
            guard k >= 0, k < listedSlots(s) else { return nil }
            let origin = s.origin ?? 0
            let start = TimeInterval(k * slotDuration) + origin
            let end = start + TimeInterval(slotDuration)
            let cues = s.cues.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
            return WebVTT.document(cues, origin: origin)
        }
    }

    private func listedSlots(_ s: State) -> Int {
        guard s.origin != nil else { return 0 }
        if let duration = s.finalDuration { return Int((duration / TimeInterval(slotDuration)).rounded(.up)) }
        return max(0, Int(((s.readThrough - holdback) / TimeInterval(slotDuration)).rounded(.down)))
    }
}
