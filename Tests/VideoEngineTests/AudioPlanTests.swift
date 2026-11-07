import Foundation
import Testing
@testable import VideoEngine

struct AudioPlanTests {
    private func stream(_ index: Int, _ codec: String, channels: Int = 2, isDefault: Bool = false,
                        asc: [UInt8] = []) -> AudioStreamFacts {
        AudioStreamFacts(index: index, codec: codec, channels: channels, sampleRate: 48_000, bitsPerSample: 16,
                         isDefault: isDefault, audioSpecificConfig: asc)
    }

    @Test func picksThePreferredStreamThenTheDefaultThenTheFirst() {
        let streams = [stream(1, "ac3"), stream(2, "aac", isDefault: true, asc: [0x11, 0x90])]
        #expect(AudioPlan.decide(streams, policy: AudioPolicy())?.streamIndex == 2)
        #expect(AudioPlan.decide(streams, policy: AudioPolicy(preferredIndex: 1))?.streamIndex == 1)
        #expect(AudioPlan.decide([stream(3, "ac3"), stream(4, "ac3")], policy: AudioPolicy())?.streamIndex == 3)
        #expect(AudioPlan.decide([], policy: AudioPolicy()) == nil)
    }

    @Test func copiesProvenFormatsAndReencodesTheRest() {
        let policy = AudioPolicy()
        func action(_ facts: AudioStreamFacts) -> AudioPlan.Action? { AudioPlan.decide([facts], policy: policy)?.action }
        // AAC-LC stereo and HE-AAC with explicit SBR copy; a program config element (channels 0) does not.
        #expect(action(stream(0, "aac", asc: [0x11, 0x90])) == .copy)
        #expect(action(stream(0, "aac", asc: [0x29, 0x90])) == .copy)
        #expect(action(stream(0, "aac", asc: [0x11, 0x80])) == .reencode(channels: 2, bitRate: 192_000))
        #expect(action(stream(0, "eac3", channels: 6)) == .copy)
        #expect(action(stream(0, "eac3", channels: 8)) == .copyCore)
        #expect(action(stream(0, "truehd", channels: 8)) == .reencode(channels: 6, bitRate: 384_000))
        #expect(action(stream(0, "opus")) == .reencode(channels: 2, bitRate: 192_000))
        #expect(action(stream(0, "flac", channels: 6)) == .reencode(channels: 6, bitRate: 384_000))
        #expect(AudioPlan.decide([stream(0, "ac3")], policy: policy, forceReencode: true)?.copiedCodec == nil)
    }
}
