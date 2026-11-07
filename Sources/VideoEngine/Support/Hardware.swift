import AVFoundation
import CoreMedia
import Foundation
import Libavcodec
import Libavfilter
import Libavutil
import Metal
import os
import VideoToolbox

/// Whether a device decodes a stream in hardware. Only a real device answers: the simulator's
/// VideoToolbox is not representative, so it reports `.unknown`.
public enum DecodeVerdict: String, Sendable, Codable {
    case hardware, softwareOnly, unsupported, unknown
}

/// The video a decode verdict is asked for.
public struct VideoStreamFacts: Sendable, Hashable {
    public var codecType: CMVideoCodecType
    public var width: Int
    public var height: Int
    public var bitDepth: Int
    /// Codec profile and level as the container states them; they only key the cache.
    public var profile: Int?
    public var level: Int?
    /// Sample description atoms, such as "hvcC" or "avcC" holding the container's codec private data.
    /// Hardware HEVC and H.264 sessions can refuse a description without them.
    public var configurationAtoms: [String: Data]

    public init(codecType: CMVideoCodecType, width: Int, height: Int, bitDepth: Int = 8, profile: Int? = nil,
                level: Int? = nil, configurationAtoms: [String: Data] = [:]) {
        self.codecType = codecType
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.profile = profile
        self.level = level
        self.configurationAtoms = configurationAtoms
    }

    /// VideoToolbox's codec type for an FFmpeg codec name, as `MediaInfo` reports it.
    public static func codecType(ffmpegName: String) -> CMVideoCodecType? {
        switch ffmpegName {
        case "h264": kCMVideoCodecType_H264
        case "hevc": kCMVideoCodecType_HEVC
        case "av1": kCMVideoCodecType_AV1
        case "vp9": kCMVideoCodecType_VP9
        case "mpeg2video": kCMVideoCodecType_MPEG2Video
        case "mpeg4": kCMVideoCodecType_MPEG4Video
        case "prores": kCMVideoCodecType_AppleProRes422
        default: nil
        }
    }

    var codecName: String { fourCC(codecType) }

    /// Codec, profile, level, size class and bit depth: what decides a decoder's answer.
    var cacheKey: String {
        let side = max(width, height)
        let size = side <= 1024 ? "sd" : side <= 1280 ? "720" : side <= 1920 ? "1080" : side <= 2560 ? "1440"
            : side <= 3840 ? "2160" : "4320"
        return "\(codecName)-\(profile ?? -1)-\(level ?? -1)-\(size)-\(bitDepth)"
    }
}

/// Answers whether this device decodes a stream in hardware: the VideoToolbox gate for the codec, then a
/// decompression session that demands a hardware decoder. Probes run one at a time off the caller's
/// thread; verdicts are cached in memory and, with `persistent`, in `UserDefaults` until the OS or the
/// device changes. Each probe adds a `hw-probe` line to `EngineDiagnostics.report()`.
public final class HardwareDecodeProbe: Sendable {
    public static let shared = HardwareDecodeProbe()

    private static let storeKey = "VideoEngine.HardwareDecodeProbe"
    private static let stamp = ProcessInfo.processInfo.operatingSystemVersionString + " " + SystemFacts.machine
    private let persistent: Bool
    private let queue = DispatchQueue(label: "videoengine-hw-probe", qos: .userInitiated)
    private let verdicts = OSAllocatedUnfairLock(initialState: [String: DecodeVerdict]())

    public init(persistent: Bool = true) {
        self.persistent = persistent
    }

    public func verdict(for stream: VideoStreamFacts) async -> DecodeVerdict {
        let key = stream.cacheKey
        if let known = verdicts.withLock({ $0[key] }) ?? stored(key) { return known }
        let started = DispatchTime.now()
        let (verdict, status) = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.probe(stream)) }
        }
        verdicts.withLock { $0[key] = verdict }
        store(key, verdict)
        EngineDiagnostics.note(
            "hw-probe codec=\(stream.codecName) prof=\(stream.profile.map(String.init) ?? "-") "
                + "lvl=\(stream.level.map(String.init) ?? "-") wh=\(stream.width)x\(stream.height) bits=\(stream.bitDepth) "
                + "verdict=\(verdict.rawValue) err=\(status.map(String.init) ?? "-") ms=\(milliseconds(since: started))"
        )
        return verdict
    }

    /// Blocking. Returns the verdict and the failing status, if any.
    private static func probe(_ stream: VideoStreamFacts) -> (DecodeVerdict, OSStatus?) {
        #if targetEnvironment(simulator)
        return (.unknown, nil)
        #else
        guard VTIsHardwareDecodeSupported(stream.codecType) else { return (.unsupported, nil) }
        guard #available(iOS 17.0, *) else { return (.unknown, nil) }
        var extensions: [CFString: Any] = [:]
        if !stream.configurationAtoms.isEmpty {
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = stream.configurationAtoms
        }
        if stream.bitDepth > 8 { extensions[kCMFormatDescriptionExtension_BitsPerComponent] = stream.bitDepth }
        var description: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: stream.codecType, width: Int32(stream.width),
            height: Int32(stream.height), extensions: extensions as CFDictionary, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { return (.unknown, status) }
        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var session: VTDecompressionSession?
        status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: description, decoderSpecification: specification,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session
        )
        // No hardware decoder takes this stream; whether software would is for the player to find out.
        guard status == noErr, let session else { return (.softwareOnly, status) }
        defer { VTDecompressionSessionInvalidate(session) }
        var used: CFTypeRef?
        _ = VTSessionCopyProperty(
            session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &used
        )
        return ((used as? Bool) == true ? .hardware : .softwareOnly, nil)
        #endif
    }

    private func stored(_ key: String) -> DecodeVerdict? {
        guard persistent, let saved = UserDefaults.standard.dictionary(forKey: Self.storeKey),
              saved["stamp"] as? String == Self.stamp,
              let raw = (saved["verdicts"] as? [String: String])?[key] else { return nil }
        return DecodeVerdict(rawValue: raw)
    }

    private func store(_ key: String, _ verdict: DecodeVerdict) {
        guard persistent, verdict != .unknown else { return }
        let saved = UserDefaults.standard.dictionary(forKey: Self.storeKey)
        var known = saved?["stamp"] as? String == Self.stamp ? saved?["verdicts"] as? [String: String] ?? [:] : [:]
        known[key] = verdict.rawValue
        UserDefaults.standard.set(["stamp": Self.stamp, "verdicts": known], forKey: Self.storeKey)
    }
}

/// What this device can do for playback: decoders, encoders, display, compute and power, in one value a
/// planner can take and a test can fix.
public struct HardwareCapabilities: Sendable, Equatable, Codable {
    public enum Support: String, Sendable, Equatable, Codable {
        case hardware, softwareOnly, none, unknown

        var code: String {
            switch self {
            case .hardware: "hw"
            case .softwareOnly: "sw"
            case .none: "no"
            case .unknown: "?"
            }
        }
    }

    public enum Thermal: String, Sendable, Equatable, Codable, Comparable {
        case nominal, fair, serious, critical

        public init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            default: self = .critical
            }
        }

        public static func < (lhs: Thermal, rhs: Thermal) -> Bool {
            let order: [Thermal] = [.nominal, .fair, .serious, .critical]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    /// The VideoToolbox gate per codec. A per-file answer comes from `HardwareDecodeProbe`.
    public struct Decode: Sendable, Equatable, Codable {
        public var h264, hevc, hevc10, dolbyVisionHEVC, av1, vp9, mpeg2, prores: Support

        public init(h264: Support, hevc: Support, hevc10: Support, dolbyVisionHEVC: Support, av1: Support,
                    vp9: Support, mpeg2: Support, prores: Support) {
            self.h264 = h264
            self.hevc = hevc
            self.hevc10 = hevc10
            self.dolbyVisionHEVC = dolbyVisionHEVC
            self.av1 = av1
            self.vp9 = vp9
            self.mpeg2 = mpeg2
            self.prores = prores
        }
    }

    public struct Encode: Sendable, Equatable, Codable {
        public var hevc, h264: Support

        public init(hevc: Support, h264: Support) {
            self.hevc = hevc
            self.h264 = h264
        }
    }

    /// Display facts only UIKit and AVFoundation know; the app reads them on the main actor.
    public struct Display: Sendable, Equatable, Codable {
        /// `AVPlayer.eligibleForHDRPlayback`: false sends HDR and Dolby Vision sources to a server transcode.
        public var hdrPlaybackEligible: Bool
        /// `UIScreen.potentialEDRHeadroom` and `currentEDRHeadroom`; 1 means no headroom.
        public var edrHeadroomPotential: Double
        public var edrHeadroomCurrent: Double
        public var maxFramesPerSecond: Int
        /// P3 rather than sRGB.
        public var wideGamut: Bool
        /// The scene is being recorded or mirrored (`sceneCaptureState`).
        public var capturing: Bool
        /// AirPlay video or an external display is in use.
        public var externalPlaybackActive: Bool

        public init(hdrPlaybackEligible: Bool, edrHeadroomPotential: Double = 1, edrHeadroomCurrent: Double = 1,
                    maxFramesPerSecond: Int = 60, wideGamut: Bool = false, capturing: Bool = false,
                    externalPlaybackActive: Bool = false) {
            self.hdrPlaybackEligible = hdrPlaybackEligible
            self.edrHeadroomPotential = edrHeadroomPotential
            self.edrHeadroomCurrent = edrHeadroomCurrent
            self.maxFramesPerSecond = maxFramesPerSecond
            self.wideGamut = wideGamut
            self.capturing = capturing
            self.externalPlaybackActive = externalPlaybackActive
        }

        public static let unknown = Display(hdrPlaybackEligible: false)
    }

    /// Battery facts from `UIDevice`, nil when monitoring is off.
    public struct Battery: Sendable, Equatable, Codable {
        public var level: Float?
        public var charging: Bool?

        public init(level: Float? = nil, charging: Bool? = nil) {
            self.level = level
            self.charging = charging
        }
    }

    public struct Power: Sendable, Equatable, Codable {
        public var thermal: Thermal
        public var lowPowerMode: Bool
        public var battery: Battery

        public init(thermal: Thermal, lowPowerMode: Bool, battery: Battery = Battery()) {
            self.thermal = thermal
            self.lowPowerMode = lowPowerMode
            self.battery = battery
        }

        /// Optional work (enhancement, interpolation, prefetch beyond the minimum) backs off.
        public var shouldShedOptionalWork: Bool { thermal >= .serious || lowPowerMode }
    }

    /// Identity and compute facts. `machine` and the OS labels are for the report, never decisions.
    public struct Compute: Sendable, Equatable, Codable {
        public var appVersion: String
        public var osVersion: String
        public var osBuild: String
        public var machine: String
        public var simulator: Bool
        public var logicalCores: Int?
        public var performanceCores: Int?
        public var efficiencyCores: Int?
        public var memoryMB: Int
        public var metal3: Bool

        public init(appVersion: String, osVersion: String, osBuild: String, machine: String, simulator: Bool,
                    logicalCores: Int?, performanceCores: Int?, efficiencyCores: Int?, memoryMB: Int, metal3: Bool) {
            self.appVersion = appVersion
            self.osVersion = osVersion
            self.osBuild = osBuild
            self.machine = machine
            self.simulator = simulator
            self.logicalCores = logicalCores
            self.performanceCores = performanceCores
            self.efficiencyCores = efficiencyCores
            self.memoryMB = memoryMB
            self.metal3 = metal3
        }
    }

    /// What the bundled FFmpeg build offers.
    public struct Engine: Sendable, Equatable, Codable {
        public var ffmpegVersion: String
        public var dav1d: Bool
        public var videoToolboxAcceleration: Bool
        /// VideoToolbox filters present, such as "scale_vt".
        public var hardwareFilters: [String]
        /// AudioToolbox codecs present: "aac_at" (encoder), "ac3_at", "eac3_at", "alac_at", "mp3_at".
        public var audioToolboxCodecs: [String]

        public init(ffmpegVersion: String, dav1d: Bool, videoToolboxAcceleration: Bool, hardwareFilters: [String],
                    audioToolboxCodecs: [String]) {
            self.ffmpegVersion = ffmpegVersion
            self.dav1d = dav1d
            self.videoToolboxAcceleration = videoToolboxAcceleration
            self.hardwareFilters = hardwareFilters
            self.audioToolboxCodecs = audioToolboxCodecs
        }
    }

    public var decode: Decode
    public var encode: Encode
    public var display: Display
    public var power: Power
    public var compute: Compute
    public var engine: Engine

    public init(decode: Decode, encode: Encode, display: Display, power: Power, compute: Compute, engine: Engine) {
        self.decode = decode
        self.encode = encode
        self.display = display
        self.power = power
        self.compute = compute
        self.engine = engine
    }

    /// The `hw-*` lines of the field report, one fact group per line.
    public func reportLines() -> [String] {
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        func count(_ value: Int?) -> String { value.map(String.init) ?? "?" }
        let d = decode
        let audio = ["aac_at", "ac3_at", "eac3_at", "alac_at", "mp3_at"]
            .map { "\($0)=\(flag(engine.audioToolboxCodecs.contains($0)))" }.joined(separator: " ")
        return [
            "hw-id v=1 app=\(compute.appVersion) os=\(compute.osVersion) build=\(compute.osBuild) "
                + "machine=\(compute.machine) sim=\(flag(compute.simulator))",
            "hw-cpu logical=\(count(compute.logicalCores)) perf=\(count(compute.performanceCores)) "
                + "eff=\(count(compute.efficiencyCores)) ram_mb=\(compute.memoryMB)",
            "hw-gpu metal3=\(flag(compute.metal3))",
            "hw-dec h264=\(d.h264.code) hevc=\(d.hevc.code) hevc10=\(d.hevc10.code) dv=\(d.dolbyVisionHEVC.code) "
                + "av1=\(d.av1.code) vp9=\(d.vp9.code) mpeg2=\(d.mpeg2.code) prores=\(d.prores.code)",
            "hw-enc hevc=\(encode.hevc.code) h264=\(encode.h264.code)",
            "hw-disp hdr_ok=\(flag(display.hdrPlaybackEligible)) "
                + String(format: "edr_pot=%.1f edr_cur=%.1f", display.edrHeadroomPotential, display.edrHeadroomCurrent)
                + " maxfps=\(display.maxFramesPerSecond) gamut=\(display.wideGamut ? "p3" : "srgb") "
                + "capture=\(flag(display.capturing)) ext=\(flag(display.externalPlaybackActive))",
            "hw-pwr thermal=\(power.thermal.rawValue) lpm=\(flag(power.lowPowerMode)) "
                + "batt=\(power.battery.level.map { String(format: "%.2f", $0) } ?? "?") "
                + "chg=\(power.battery.charging.map(flag) ?? "?")",
            "hw-aud \(audio)",
            "hw-eng ffmpeg=\(engine.ffmpegVersion) dav1d=\(flag(engine.dav1d)) "
                + "hwaccel=\(engine.videoToolboxAcceleration ? "videotoolbox" : "none") "
                + "vf=\(engine.hardwareFilters.isEmpty ? "-" : engine.hardwareFilters.joined(separator: ","))",
        ]
    }

    /// The `hw-state` line: what changes while the app runs.
    var stateLine: String {
        "hw-state thermal=\(power.thermal.rawValue) lpm=\(power.lowPowerMode ? 1 : 0) "
            + "hdr_ok=\(display.hdrPlaybackEligible ? 1 : 0) ext=\(display.externalPlaybackActive ? 1 : 0)"
    }
}

public protocol HardwareCapabilityProviding: Sendable {
    func snapshot() async -> HardwareCapabilities
    func decodeVerdict(for stream: VideoStreamFacts) async -> DecodeVerdict
}

/// A provider that always answers the same, for tests and previews.
public struct FixedHardwareCapabilityProvider: HardwareCapabilityProviding {
    public var capabilities: HardwareCapabilities
    public var verdict: DecodeVerdict

    public init(_ capabilities: HardwareCapabilities, verdict: DecodeVerdict = .hardware) {
        self.capabilities = capabilities
        self.verdict = verdict
    }

    public func snapshot() async -> HardwareCapabilities { capabilities }
    public func decodeVerdict(for stream: VideoStreamFacts) async -> DecodeVerdict { verdict }
}

/// Reads the device. The fixed part (decoders, encoders, compute, engine) is measured once; display,
/// battery, heat and Low Power Mode are read on every snapshot. The first snapshot adds the `hw-*` lines
/// to `EngineDiagnostics.report()`, later ones a `hw-state` line when heat, Low Power Mode, HDR
/// eligibility or external playback changed.
public final class LiveHardwareCapabilityProvider: HardwareCapabilityProviding {
    private let display: @Sendable () async -> HardwareCapabilities.Display
    private let battery: @Sendable () async -> HardwareCapabilities.Battery
    private let probe: HardwareDecodeProbe
    private let state = OSAllocatedUnfairLock<(fixed: Fixed?, lastState: String?)>(initialState: (nil, nil))

    private struct Fixed: Sendable {
        var decode: HardwareCapabilities.Decode
        var encode: HardwareCapabilities.Encode
        var compute: HardwareCapabilities.Compute
        var engine: HardwareCapabilities.Engine
    }

    /// - Parameters:
    ///   - display: reads `AVPlayer.eligibleForHDRPlayback`, the screen's EDR headroom, frame rate and
    ///     gamut, `sceneCaptureState` and external playback; it runs on the main actor in the app.
    ///   - battery: reads `UIDevice` battery level and state, when the app monitors them.
    public init(
        display: @escaping @Sendable () async -> HardwareCapabilities.Display,
        battery: @escaping @Sendable () async -> HardwareCapabilities.Battery = { HardwareCapabilities.Battery() },
        probe: HardwareDecodeProbe = .shared
    ) {
        self.display = display
        self.battery = battery
        self.probe = probe
    }

    public func snapshot() async -> HardwareCapabilities {
        let fixed = state.withLock { $0.fixed } ?? measureFixed()
        let info = ProcessInfo.processInfo
        let capabilities = HardwareCapabilities(
            decode: fixed.decode, encode: fixed.encode, display: await display(),
            power: HardwareCapabilities.Power(
                thermal: HardwareCapabilities.Thermal(info.thermalState), lowPowerMode: info.isLowPowerModeEnabled,
                battery: await battery()
            ),
            compute: fixed.compute, engine: fixed.engine
        )
        let line = capabilities.stateLine
        let (first, changed) = state.withLock { s -> (Bool, Bool) in
            defer {
                s.fixed = fixed
                s.lastState = line
            }
            return (s.lastState == nil, s.lastState != line)
        }
        if first {
            for line in capabilities.reportLines() { EngineDiagnostics.note(line) }
        } else if changed {
            EngineDiagnostics.note(line)
        }
        return capabilities
    }

    public func decodeVerdict(for stream: VideoStreamFacts) async -> DecodeVerdict {
        await probe.verdict(for: stream)
    }

    /// Snapshots each time heat, Low Power Mode or HDR eligibility changes. Screen and scene changes are
    /// the app's to observe; it calls `snapshot()` for them.
    public func changes() -> AsyncStream<HardwareCapabilities> {
        AsyncStream { continuation in
            let names: [Notification.Name] = [
                ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange,
                AVPlayer.eligibleForHDRPlaybackDidChangeNotification,
            ]
            let tasks = names.map { name in
                Task { [self] in
                    for await _ in NotificationCenter.default.notifications(named: name) {
                        continuation.yield(await snapshot())
                    }
                }
            }
            continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
        }
    }

    private func measureFixed() -> Fixed {
        func gate(_ type: CMVideoCodecType) -> HardwareCapabilities.Support {
            #if targetEnvironment(simulator)
            return .unknown
            #else
            return VTIsHardwareDecodeSupported(type) ? .hardware : .none
            #endif
        }
        func encoder(_ type: CMVideoCodecType) -> HardwareCapabilities.Support {
            #if targetEnvironment(simulator)
            return .unknown
            #else
            guard #available(iOS 17.4, *) else { return .unknown }
            let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
            var id: CFString?
            var properties: CFDictionary?
            let status = VTCopySupportedPropertyDictionaryForEncoder(
                width: 1920, height: 1080, codecType: type, encoderSpecification: specification,
                encoderIDOut: &id, supportedPropertiesOut: &properties
            )
            return status == noErr ? .hardware : .none
            #endif
        }
        let hevc = gate(kCMVideoCodecType_HEVC)
        let decode = HardwareCapabilities.Decode(
            // Every device iOS 16 runs on decodes HEVC Main10 wherever it decodes HEVC.
            h264: gate(kCMVideoCodecType_H264), hevc: hevc, hevc10: hevc,
            dolbyVisionHEVC: gate(kCMVideoCodecType_DolbyVisionHEVC), av1: gate(kCMVideoCodecType_AV1),
            vp9: gate(kCMVideoCodecType_VP9), mpeg2: gate(kCMVideoCodecType_MPEG2Video),
            prores: gate(kCMVideoCodecType_AppleProRes422)
        )
        let encode = HardwareCapabilities.Encode(hevc: encoder(kCMVideoCodecType_HEVC), h264: encoder(kCMVideoCodecType_H264))
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        let compute = HardwareCapabilities.Compute(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            osVersion: "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
            osBuild: SystemFacts.string("kern.osversion") ?? "?", machine: SystemFacts.machine, simulator: simulator,
            logicalCores: SystemFacts.integer("hw.logicalcpu"), performanceCores: SystemFacts.integer("hw.perflevel0.logicalcpu"),
            efficiencyCores: SystemFacts.integer("hw.perflevel1.logicalcpu"),
            memoryMB: Int(ProcessInfo.processInfo.physicalMemory >> 20),
            metal3: MTLCreateSystemDefaultDevice()?.supportsFamily(.metal3) ?? false
        )
        let engine = HardwareCapabilities.Engine(
            ffmpegVersion: String(cString: av_version_info()), dav1d: avcodec_find_decoder_by_name("libdav1d") != nil,
            videoToolboxAcceleration: av_hwdevice_find_type_by_name("videotoolbox") != AV_HWDEVICE_TYPE_NONE,
            hardwareFilters: ["scale_vt", "transpose_vt", "yadif_videotoolbox"].filter { avfilter_get_by_name($0) != nil },
            audioToolboxCodecs: (avcodec_find_encoder_by_name("aac_at") != nil ? ["aac_at"] : [])
                + ["ac3_at", "eac3_at", "alac_at", "mp3_at"].filter { avcodec_find_decoder_by_name($0) != nil }
        )
        return Fixed(decode: decode, encode: encode, compute: compute, engine: engine)
    }
}

enum SystemFacts {
    static let machine: String = string("hw.machine") ?? "?"

    static func integer(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
    return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? String(decoding: bytes, as: UTF8.self) : String(code)
}
