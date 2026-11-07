import Foundation
import os
import Testing
@testable import VideoEngine

struct TranscodeTests {
    @Test func outputSizeKeepsAspectAndEvenSides() {
        #expect(TranscodeMath.outputSize(width: 3840, height: 2160, maxLongEdge: 1920) == (1920, 1080))
        #expect(TranscodeMath.outputSize(width: 1080, height: 1920, maxLongEdge: 1280) == (720, 1280))
        #expect(TranscodeMath.outputSize(width: 1001, height: 501, maxLongEdge: nil) == (1002, 502))
        #expect(TranscodeMath.outputSize(width: 0, height: 0, maxLongEdge: nil) == (1280, 720))
    }

    @Test func bitrateFollowsTheLadderAndNeverInflates() {
        let medium = TranscodeSettings(codec: .h264, quality: .medium)
        #expect(TranscodeMath.videoBitrate(width: 1000, height: 1000, fps: 30, settings: medium) == 4_000_000)
        #expect(TranscodeMath.videoBitrate(width: 1000, height: 1000, fps: 30, settings: medium, sourceBitrate: 5_000_000) == 3_000_000)
        let hevc = TranscodeSettings(codec: .hevc, quality: .low)
        #expect(TranscodeMath.videoBitrate(width: 640, height: 360, fps: 30, settings: hevc) == 500_000)
        let fixed = TranscodeSettings(codec: .h264, quality: .high, bitrateOverride: 1_234_000)
        #expect(TranscodeMath.videoBitrate(width: 1920, height: 1080, fps: 60, settings: fixed, sourceBitrate: 100_000) == 1_234_000)
    }

    @Test func chunkPlanStartsEachChunkOnAKeyframe() {
        // Keyframes every 2 s in a 1/1000 time base.
        let plan = ChunkPlan.make(keyframes: Array(stride(from: Int64(0), to: 50_000, by: 2000)), tbNum: 1, tbDen: 1000, key: "k")
        #expect(plan.chunks == [.init(start: 0, end: 20_000), .init(start: 20_000, end: 40_000), .init(start: 40_000, end: .max)])
        #expect(ChunkPlan.make(keyframes: [500], tbNum: 1, tbDen: 1000, key: "k").chunks == [.init(start: 500, end: .max)])
    }

    @Test func chunkPlanKeepsTheEarlierFileFormat() throws {
        let json = #"{"version":1,"settingsKey":"720p-medium-hevc","tbNum":1,"tbDen":1000,"chunks":[{"start":0,"end":9223372036854775807}]}"#
        let plan = try JSONDecoder().decode(ChunkPlan.self, from: Data(json.utf8))
        #expect(plan.settingsKey == "720p-medium-hevc")
        #expect(plan.chunks == [.init(start: 0, end: .max)])
    }

    /// Same codec and size: the transcoder copies the streams instead of re-encoding.
    @Test func copiesStreamsWhenNothingWouldChange() async throws {
        let output = Fixture.temporaryURL(".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let progress = OSAllocatedUnfairLock(initialState: [Double]())
        let observer = TranscodeObserver(progress: { value in progress.withLock { $0.append(value) } })
        try await FileTranscoder().run(
            input: Fixture.url("h264-aac.mkv"), output: output, settings: TranscodeSettings(codec: .h264, quality: .high),
            observer: observer
        )
        let info = try await MediaProbe.probe(url: output)
        #expect(info.video.map(\.codec) == ["h264"])
        #expect(info.audio.map(\.codec) == ["aac"])
        #expect(abs((info.duration ?? 0) - 3) < 0.2)
        #expect(progress.withLock { $0.last } == 1)
    }

    @Test func cancelledTranscoderStaysCancelled() async throws {
        let transcoder = FileTranscoder()
        transcoder.cancel()
        let output = Fixture.temporaryURL(".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        await #expect(throws: CancellationError.self) {
            try await transcoder.run(
                input: Fixture.url("h264-aac.mkv"), output: output, settings: TranscodeSettings(codec: .h264, quality: .high),
                observer: TranscodeObserver()
            )
        }
    }
}
