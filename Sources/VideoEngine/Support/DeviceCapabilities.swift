import CoreMedia
import VideoToolbox

/// Hardware decode capabilities of the current device, queried once.
public enum DeviceCapabilities {
    /// True when the device has a hardware AV1 decoder (A17 Pro, M3 and later), so AV1 can be remuxed
    /// into an `av01` MP4 and decoded by AVPlayer instead of transcoded.
    public static let av1HardwareDecode: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
}
