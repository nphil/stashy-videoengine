// Swift-level validation that all six clang modules import and their C symbols
// are visible from Swift, against the flattened header layout SwiftPM produces.
// Type-checked only (swiftc -typecheck); never run.
import Libavutil
import Libavcodec
import Libavformat
import Libavfilter
import Libswscale
import Libswresample

@_cdecl("stashy_swift_import_check")
func stashySwiftImportCheck() -> Int32 {
    _ = avformat_version()
    _ = swscale_version()
    _ = swresample_version()
    _ = avfilter_version()
    _ = avutil_version()
    let enc = avcodec_find_encoder_by_name("h264_videotoolbox")
    return enc != nil ? 0 : 1
}
