import CoreMedia
import Foundation
import Testing
@testable import VideoEngine

struct HardwareTests {
    private static let capabilities = HardwareCapabilities(
        decode: .init(h264: .hardware, hevc: .hardware, hevc10: .hardware, dolbyVisionHEVC: .hardware, av1: .none,
                      vp9: .none, mpeg2: .none, prores: .hardware),
        encode: .init(hevc: .hardware, h264: .unknown),
        display: .init(hdrPlaybackEligible: true, edrHeadroomPotential: 8, maxFramesPerSecond: 120, wideGamut: true),
        power: .init(thermal: .serious, lowPowerMode: false, battery: .init(level: 0.82, charging: false)),
        compute: .init(appVersion: "1.0", osVersion: "27.0", osBuild: "25A100", machine: "iPhone17,1", simulator: false,
                       logicalCores: 6, performanceCores: 2, efficiencyCores: 4, memoryMB: 7791, metal3: true),
        engine: .init(ffmpegVersion: "8.1", dav1d: true, videoToolboxAcceleration: true, hardwareFilters: ["scale_vt"],
                      audioToolboxCodecs: ["aac_at", "eac3_at"])
    )

    @Test func reportsOneLinePerFactGroup() {
        let lines = Self.capabilities.reportLines()
        #expect(lines.map { $0.split(separator: " ")[0] } == [
            "hw-id", "hw-cpu", "hw-gpu", "hw-dec", "hw-enc", "hw-disp", "hw-pwr", "hw-aud", "hw-eng",
        ])
        #expect(lines.contains("hw-dec h264=hw hevc=hw hevc10=hw dv=hw av1=no vp9=no mpeg2=no prores=hw"))
        #expect(lines.contains("hw-disp hdr_ok=1 edr_pot=8.0 edr_cur=1.0 maxfps=120 gamut=p3 capture=0 ext=0"))
        #expect(lines.contains("hw-pwr thermal=serious lpm=0 batt=0.82 chg=0"))
        #expect(lines.contains("hw-aud aac_at=1 ac3_at=0 eac3_at=1 alac_at=0 mp3_at=0"))
    }

    @Test func heatOrLowPowerModeShedsOptionalWork() {
        #expect(HardwareCapabilities.Power(thermal: .serious, lowPowerMode: false).shouldShedOptionalWork)
        #expect(HardwareCapabilities.Power(thermal: .nominal, lowPowerMode: true).shouldShedOptionalWork)
        #expect(!HardwareCapabilities.Power(thermal: .fair, lowPowerMode: false).shouldShedOptionalWork)
    }

    @Test func probeVerdictsAreCachedByCodecProfileAndSize() {
        let base = VideoStreamFacts(codecType: kCMVideoCodecType_HEVC, width: 3840, height: 2160, bitDepth: 10, profile: 2)
        var sameClass = base
        sameClass.width = 3832
        sameClass.configurationAtoms = ["hvcC": Data([1])]
        var smaller = base
        smaller.width = 1920
        #expect(base.cacheKey == "hvc1-2--1-2160-10")
        #expect(sameClass.cacheKey == base.cacheKey)
        #expect(smaller.cacheKey != base.cacheKey)
        #expect(VideoStreamFacts.codecType(ffmpegName: "hevc") == kCMVideoCodecType_HEVC)
    }
}
