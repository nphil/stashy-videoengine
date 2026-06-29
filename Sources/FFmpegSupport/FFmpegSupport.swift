// Linker shim. This target carries no API; it exists so SwiftPM can attach the
// system-library and framework linker settings the FFmpeg static libraries
// need (zlib + the VideoToolbox stack), and so the single "FFmpeg" product
// transitively pulls in all six binary xcframeworks. App code imports the
// individual modules (Libavformat, Libavcodec, ...), not this target.
public enum FFmpegSupport {
    /// The FFmpeg release these binaries were built from.
    public static let ffmpegVersion = "n7.1.5"
}
