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

**FFmpeg version:** `n8.1.2` · **Min iOS:** 16.0 · **License:** LGPL-2.1+

### Enabled capabilities (comprehensive LGPL build, v1.1.0+)

This is a **full non-GPL FFmpeg build** — every built-in LGPL filter, decoder,
demuxer, muxer, parser and bitstream filter is compiled in, plus the external
filter libraries below. Static dead-strip means the app only links what it
actually calls, so the broad catalog never needs another rebuild to add a
filter. GPL is off (no `--enable-gpl`, no x264/x265, no libpostproc).

- **Hardware encode:** `h264_videotoolbox`, `hevc_videotoolbox`,
  `prores_videotoolbox` (new in 8.x), native `aac`; `mov_text` for soft
  subtitles into MP4.
- **Decode (everything non-GPL):** h264/hevc/vp8/vp9/av1/mpeg*/vc1/theora video;
  aac/ac3/eac3/opus/vorbis/flac/mp3/alac plus **dca (DTS)/truehd/mlp/wma*** that
  AVPlayer can't decode (transcode to AAC); subtitles
  subrip/ass/webvtt/mov_text/dvdsub/dvbsub/**pgssub**/microdvd. AV1 decodes via
  **libdav1d** (fast reference decoder) in software, and via the
  `av1_videotoolbox` hardware hwaccel on devices that support it (M3/A17 Pro+).
- **Filters:** the full built-in LGPL set (scale, zscale, format, colorspace,
  curves, lut3d, tonemap, unsharp, cas, atadenoise, nlmeans, deband, yadif,
  bwdif, crop, pad, transpose, fps, setpts, overlay, hstack/vstack, aresample,
  volume, loudnorm, dynaudnorm, atempo, …) **+ external:** `zscale` (libzimg, HQ
  scale/colorspace/HDR), `drawtext` (libfreetype/harfbuzz/fribidi),
  `subtitles`/`ass` (libass burn-in). Hardware: `yadif_videotoolbox` (Metal) and
  — now that min-iOS is 16 — `scale_vt`/`transpose_vt` (VideoToolbox HW
  scale/rotate on pixel buffers).
  > `tonemap_vt` does not exist in FFmpeg; software `tonemap` + `zscale` cover
  > HDR→SDR. The GPL `cropdetect`/`eq`/`hqdn3d` filters are excluded (LGPL build).
- **Demux/Mux:** all non-GPL (matroska/webm, mov/mp4, avi, flv, mpegts, asf,
  ogg, hls, wav, …); muxers include mov/mp4/mpegts plus **hls** and **segment**.
  Fragmented MP4 at runtime via `movflags=frag_keyframe+empty_moov+default_base_moof`.
- **Bitstream filters:** all non-GPL (h264/hevc_mp4toannexb, aac_adtstoasc,
  extract_extradata, vp9_superframe, av1_metadata, …).
- **Protocols:** file, pipe, **http, https, tls** (SecureTransport). The app may
  still feed remote input via a custom `AVIOContext`; networking is a fallback.

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

- System libraries: `z`, `bz2`, `iconv`, `c++` (libc++, for the C++ external
  libs libzimg/harfbuzz; lzma is disabled — it isn't in the iOS SDK)
- Frameworks: `VideoToolbox`, `CoreMedia`, `CoreVideo`, `CoreFoundation`,
  `Security` (SecureTransport), `AudioToolbox`, `Metal` (VideoToolbox filters)

The external filter libraries (libzimg/libfreetype/libharfbuzz/libfribidi/
libass) are merged into `libavfilter.xcframework`, so there are still exactly
six xcframeworks and nothing extra to link.

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

- **Push to `main`** → builds + verifies + uploads the zipped xcframeworks and
  `checksums.txt` as workflow artifacts.
- **Run the workflow manually with a `release_tag`** → all of the above, then
  regenerates `Package.swift` pinned to this build's SHA-256 checksums, commits
  it to `main`, tags that commit, and creates a GitHub Release with the six
  zips + `checksums.txt`.

The release is dispatch-driven (not tag-push-driven) on purpose: the tag is
created *after* the build, on the commit that already holds the matching
`Package.swift`, so a `v1.0.0` checkout resolves checksums that match the
release assets.

### Cut a release

```bash
gh workflow run "Build FFmpeg XCFrameworks" -f release_tag=v1.0.0
```

## License & attribution

The build scripts in this repo are MIT (see [LICENSE](LICENSE)). The XCFramework
**artifacts** are builds of [FFmpeg](https://ffmpeg.org), licensed under
**LGPL-2.1-or-later**:

- Configured **without** `--enable-gpl` and **without** x264/x265 — no GPL code
  is linked in.
- `h264_videotoolbox` / `hevc_videotoolbox` are Apple framework encoders; they
  pull in no GPL.
- FFmpeg source for the pinned tag: <https://github.com/FFmpeg/FFmpeg/tree/n8.1.2>

When shipping an app that links these, include FFmpeg's `COPYING.LGPLv2.1`, an
attribution notice, and an offer of the corresponding source (a link to the tag
above satisfies this). H.264/HEVC patent licensing is a separate matter from
the software license.
