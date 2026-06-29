# stashy-videoengine

Prebuilt **FFmpeg XCFrameworks for iOS**, built in CI on macOS, published as
checksummed GitHub Release assets and consumable as SwiftPM binary targets.

These power [Stashy](https://github.com/nphil)'s on-device remux/transcode of
exotic video (MKV / WebM / VP9 / AV1) into `AVPlayer`-playable fragmented MP4,
using Apple's hardware VideoToolbox encoders — so a self-hosted media server
doesn't have to transcode.

## What's in the box

Six static-library XCFrameworks, each with an **arm64 iOS-device** slice and an
**arm64 iOS-simulator** slice, plus clang module maps for Swift `import`:

| XCFramework               | Swift module    |
| ------------------------- | --------------- |
| `libavutil.xcframework`     | `Libavutil`     |
| `libavcodec.xcframework`    | `Libavcodec`    |
| `libavformat.xcframework`   | `Libavformat`   |
| `libavfilter.xcframework`   | `Libavfilter`   |
| `libswscale.xcframework`    | `Libswscale`    |
| `libswresample.xcframework` | `Libswresample` |

**FFmpeg version:** `n7.1.5` · **Min iOS:** 15.0 · **License:** LGPL-2.1+

### Enabled capabilities (LGPL-minimal)

- **Hardware encode:** `h264_videotoolbox`, `hevc_videotoolbox`, plus native `aac`
- **Decode:** h264, hevc, vp9, vp8, av1, mpeg4, mpeg2video, vc1, theora, aac,
  ac3, eac3, opus, vorbis, flac, mp3, pcm_s16le/be
- **Demux:** matroska (mkv/webm), mov/mp4, avi, flv, mpegts, asf, ogg, hls,
  aac, mp3, flac, wav
- **Mux:** mov, mp4, mpegts — fragmented MP4 is produced at runtime via
  `movflags=frag_keyframe+empty_moov+default_base_moof`
- **Bitstream filters:** h264_mp4toannexb, hevc_mp4toannexb, aac_adtstoasc
- **Filters:** scale, format, aresample, anull, null
- **Protocols:** file, pipe — remote input is fed via a custom `AVIOContext`,
  so FFmpeg's own TLS/HTTP stack is intentionally omitted.

## Consuming from the Stashy app

Add this repo as a Swift Package dependency (the `FFmpeg` product pulls in all
six binary targets plus the required system frameworks):

```swift
.package(url: "https://github.com/nphil/stashy-videoengine.git", from: "1.0.0")
```

```swift
.target(name: "Stashy", dependencies: [
    .product(name: "FFmpeg", package: "stashy-videoengine"),
])
```

Then in Swift:

```swift
import Libavformat
import Libavcodec
import Libavutil
```

The `FFmpegSupport` target attaches the linker settings FFmpeg needs, so you
don't have to add them yourself:

- System library: `z` (zlib — bz2/iconv/lzma are disabled at build time since
  liblzma isn't in the iOS SDK and the others aren't needed)
- Frameworks: `VideoToolbox`, `CoreMedia`, `CoreVideo`, `CoreFoundation`

The clang module map that makes `import Libavcodec` (etc.) work ships inside the
`libavutil.xcframework` and declares all six modules — this avoids the
`module.modulemap` filename collision that occurs when multiple static-library
xcframeworks each carry their own top-level module map.

> Vendoring instead of SwiftPM? Download the `*.xcframework.zip` assets from a
> Release, unzip, drag the six `.xcframework`s into your target, and add `libz`
> + the frameworks above under **Link Binary With Libraries**.

## How it's built

Everything runs on a GitHub Actions `macos-15` runner — there is no local Mac
in the loop.

```
scripts/build-ffmpeg.sh   # configure + build per-arch, create 6 xcframeworks
scripts/verify.sh         # inspect slices, validate module maps, run a
                          #   simulator smoke test
scripts/gen-package-swift.sh  # render Package.swift pinned to a release
scripts/release.sh        # create the Release + push the pinned manifest
.github/workflows/build.yml
```

- **Push to `main`** (or run the workflow manually) → builds + verifies +
  uploads the zipped xcframeworks and `checksums.txt` as workflow artifacts.
- **Push a `v*` tag** → all of the above, then creates a GitHub Release with
  the six zips + `checksums.txt`, regenerates `Package.swift` pinned to those
  assets (SHA-256 checksums), and pushes it back to `main`.

### Cut a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

## License & attribution

The build scripts in this repo are MIT (see [LICENSE](LICENSE)). The XCFramework
**artifacts** are builds of [FFmpeg](https://ffmpeg.org), licensed under
**LGPL-2.1-or-later**:

- Configured **without** `--enable-gpl` and **without** x264/x265 — no GPL code
  is linked in.
- `h264_videotoolbox` / `hevc_videotoolbox` are Apple framework encoders; they
  pull in no GPL.
- FFmpeg source for the pinned tag: <https://github.com/FFmpeg/FFmpeg/tree/n7.1.5>

When shipping an app that links these, include FFmpeg's `COPYING.LGPLv2.1`, an
attribution notice, and an offer of the corresponding source (a link to the tag
above satisfies this). H.264/HEVC patent licensing is a separate matter from
the software license.
