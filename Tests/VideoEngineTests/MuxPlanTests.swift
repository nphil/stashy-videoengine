import Foundation
import LoopbackHLS
import Testing
@testable import VideoEngine

struct MuxPlanTests {
    private func plan(_ record: DolbyVisionConfiguration?, audio: [String] = ["aac"],
                      options: RemuxOptions = RemuxOptions()) -> MuxPlan {
        MuxPlan.decide(videoCodec: "hevc", dolbyVision: record, audioCodecs: audio, options: options)
    }

    @Test func profile5IsWrittenAsDvh1WithUnspecifiedColour() {
        let p5 = plan(DolbyVisionConfiguration(profile: 5, level: 6, compatibilityID: 0))
        #expect(p5.videoTag == "dvh1")
        #expect(p5.dolbyVision == .keep)
        #expect(p5.unspecifiedColour)
        #expect(p5.movflags.contains("write_colr"))
        #expect(p5.muxerOptions["strict"] == "unofficial")
    }

    @Test func profile7IsCutToItsBaseLayerAndProfile8KeepsDolbyVision() {
        let p7 = plan(DolbyVisionConfiguration(profile: 7, level: 6, compatibilityID: 6, hasEnhancementLayer: true))
        #expect(p7.dolbyVision == .strip)
        #expect(p7.videoTag == "hvc1")

        let p81 = DolbyVisionConfiguration(profile: 8, level: 6, compatibilityID: 1)
        #expect(plan(p81).dolbyVision == .keep)
        #expect(plan(p81).videoTag == "hvc1")
        var baseOnly = RemuxOptions()
        baseOnly.dolbyVision = .baseLayerOnly
        #expect(plan(p81, options: baseOnly).dolbyVision == .drop)
        // An SDR base layer (8.2) is not worth a Dolby Vision label.
        #expect(plan(DolbyVisionConfiguration(profile: 8, level: 6, compatibilityID: 2)).dolbyVision == .drop)
    }

    @Test func serverRecordIsAddedOnlyWhenTheFileHasNone() {
        let server = DolbyVisionConfiguration(profile: 8, level: 6, compatibilityID: 1)
        var options = RemuxOptions()
        options.dolbyVisionFallback = server
        #expect(plan(nil, options: options).dolbyVision == .add(server))
        #expect(plan(DolbyVisionConfiguration(profile: 8, level: 9, compatibilityID: 4), options: options).dolbyVision == .keep)
        #expect(plan(nil).dolbyVision == .none)
    }

    @Test func dolbyDigitalAudioDelaysTheInitSegment() {
        let ac3 = plan(nil, audio: ["eac3"])
        #expect(ac3.movflags.contains("delay_moov"))
        #expect(ac3.muxerOptions["use_editlist"] == "0")
        #expect(!plan(nil).movflags.contains("delay_moov"))
    }
}
