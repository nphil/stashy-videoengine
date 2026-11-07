import Foundation
import LoopbackHLS

/// What becomes of Dolby Vision in an HEVC stream. Unknown values behave as `.automatic`.
public struct DolbyVisionMode: Sendable, Hashable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Profile 5 as `dvh1` with its `dvcC`; profiles 8.1 and 8.4 as `hvc1` with `dvvC`, which plays as
    /// HDR10 or HLG where Dolby Vision does not; profile 7 cut to its HDR10 base layer, the only part
    /// Apple decodes.
    public static let automatic = DolbyVisionMode(rawValue: "automatic")
    /// Profiles 7 and 8 play as their HDR10 or HLG base layer. Profile 5 has no base layer of its own and
    /// stays Dolby Vision.
    public static let baseLayerOnly = DolbyVisionMode(rawValue: "base-layer-only")
}

/// How a run writes what it copies: the HEVC sample entry, the Dolby Vision record and the muxer flags
/// the copied codecs need. Decided from codec names and the record alone, so the table is tested
/// without FFmpeg.
struct MuxPlan: Equatable {
    enum DolbyVisionAction: Equatable {
        /// No record in the source and none to add.
        case none
        /// The source's record stays; the muxer writes it as `dvcC` (profile 7 or lower) or `dvvC`.
        case keep
        /// The source has no record; this one, such as one built from server metadata, is added.
        case add(DolbyVisionConfiguration)
        /// The record goes and the pictures play as the base layer they already are.
        case drop
        /// The `dovi_rpu` filter removes the RPU and enhancement-layer NAL units along with the record.
        case strip
    }

    /// Sample entry to force on the video stream, or nil for the muxer's choice.
    var videoTag: String?
    var dolbyVision: DolbyVisionAction
    /// Profile 5 pictures are in no standard colour space until the Dolby Vision layer maps them, so the
    /// `colr` box says unspecified rather than what the container claims.
    var unspecifiedColour = false
    var movflags: [String]
    var muxerOptions: [String: String]

    static func decide(
        videoCodec: String?, dolbyVision source: DolbyVisionConfiguration?, audioCodecs: [String], options: RemuxOptions
    ) -> MuxPlan {
        // frag_keyframe starts every fragment on a video keyframe, so each one is a decodable HLS segment;
        // empty_moov puts the parameter sets in the init segment that EXT-X-MAP points at.
        var movflags = ["frag_keyframe", "empty_moov", "default_base_moof"]
        // The muxer writes dvcC and dvvC only at this compliance level.
        var muxerOptions = ["strict": "unofficial"]
        // The ac-3 and ec-3 sample entries are built from the first packet, so with empty_moov alone the
        // header fails; delay_moov writes the init segment with the first fragment instead.
        if audioCodecs.contains(where: { $0 == "ac3" || $0 == "eac3" }) {
            movflags.append("delay_moov")
            muxerOptions["use_editlist"] = "0"
        }
        movflags += options.extraMovflags
        muxerOptions.merge(options.muxerOptions) { _, chosen in chosen }

        // Dolby Vision over AVC or AV1 does not decode on Apple devices; its base layer does.
        var plan = MuxPlan(
            videoTag: nil, dolbyVision: source == nil ? .none : .drop, movflags: movflags, muxerOptions: muxerOptions
        )
        guard videoCodec == "hevc" else { return plan }
        plan.videoTag = options.hevcTag.fourCC
        guard let record = source ?? options.dolbyVisionFallback else { return plan }
        let keep: DolbyVisionAction = source == nil ? .add(record) : .keep
        switch record.profile {
        case 5:
            plan.videoTag = "dvh1"
            plan.dolbyVision = keep
            plan.unspecifiedColour = true
            plan.movflags.append("write_colr")
        case 7:
            plan.dolbyVision = .strip
        case 8 where options.dolbyVision != .baseLayerOnly && [1, 4].contains(record.compatibilityID):
            plan.dolbyVision = keep
        default:
            plan.dolbyVision = source == nil ? .none : .drop
        }
        return plan
    }
}
