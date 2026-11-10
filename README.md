# VideoEngine

Prebuilt **FFmpeg XCFrameworks for iOS**, built in CI on macOS, published as
checksummed GitHub Release assets and consumable as SwiftPM binary targets.

These enable on-device remux/transcode of
video (MKV / WebM / VP9 / AV1) into `AVPlayer`-playable fragmented MP4,
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

**FFmpeg version:** `n9.0.2` · **Min iOS:** 26.0 · **License:** LGPL-2.1+

### Enabled capabilities (comprehensive LGPL build, v1.1.0+)

This is a **full non-GPL FFmpeg build** — every built-in LGPL filter, decoder,
demuxer, muxer, parser and bitstream filter is compiled in, plus the external
filter libraries below, so adding a filter never needs a rebuild. The cost is
app size: FFmpeg's registries reference every enabled component, so an app
that links a library carries all of its components; only libraries the app
never references drop out. GPL is off (no `--enable-gpl`, no x264/x265, no
libpostproc).

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
  `subtitles`/`ass` (libass burn-in). Hardware: `yadif_videotoolbox` (Metal),
  `scale_vt`/`transpose_vt` (VideoToolbox HW scale/rotate on pixel buffers).
  > `tonemap_vt` does not exist in FFmpeg; software `tonemap` + `zscale` cover
  > HDR→SDR. The GPL `cropdetect`/`eq`/`hqdn3d` filters are excluded (LGPL build).
- **Demux/Mux:** all non-GPL (matroska/webm, mov/mp4, avi, flv, mpegts, asf,
  ogg, hls, wav, …); muxers include mov/mp4/mpegts plus **hls** and **segment**.
  Fragmented MP4 at runtime via `movflags=frag_keyframe+empty_moov+default_base_moof`.
- **Bitstream filters:** all non-GPL (h264/hevc_mp4toannexb, aac_adtstoasc,
  extract_extradata, vp9_superframe, av1_metadata, dovi_rpu, dovi_split, …).
- **Protocols:** file and pipe only. Remote input goes through the app's own
  `AVIOContext` (for example, URLSession range requests); FFmpeg's HTTP client
  and TLS are not built.

### VideoEngine library (v1.4.0+)

The `VideoEngine` product is the Swift layer that plays and downloads media on
top of these binaries (Swift 6, strict
concurrency):

- `MediaProbe.probe` returns `MediaInfo`: container, streams, colour and HDR
  details.
- `ByteRangeSources.make` reads a `file://` or `http(s)://` URL with URLSession
  range requests and feeds FFmpeg through a custom `AVIOContext`; FFmpeg never
  opens a network URL itself.
- `RemuxSession` plays what AVPlayer cannot open (Matroska, for instance): video
  is copied, without re-encoding, into a growing fragmented MP4 that
  `LoopbackServer` serves as HLS on 127.0.0.1. From v2.0.0, audio AVPlayer
  cannot play is re-encoded to AAC and text subtitles become WebVTT renditions.
- `FileTranscoder` re-encodes a local file in one VideoToolbox pass;
  `ChunkedTranscoder` works in chunks of about 20 s and resumes where an
  interrupted run stopped.
- `HardwareDecodeProbe` and `HardwareCapabilities` (v2.0.0+) report hardware
  decode support, HDR eligibility of the display, and heat and power state.
- Logging goes through an `EngineLogger` the app supplies.

The full API, adoption steps and device test sheets are in
[docs/ENGINE.md](docs/ENGINE.md). A public API change is a major version, so
apps pin an exact version.

## Consuming from an app

Add this repo as a Swift Package dependency (the `FFmpeg` product pulls in all
six binary targets plus the required system frameworks):

```swift
.package(url: "https://github.com/nphil/videoengine.git", exact: "2.0.0")
```

```swift
.target(name: "MediaApp", dependencies: [
    .product(name: "FFmpeg", package: "videoengine"),
    .product(name: "VideoEngine", package: "videoengine"),  // v1.4.0+
])
```

Migration: the canonical repository is `https://github.com/nphil/videoengine`
and the Swift package identity is `videoengine`. Products and APIs are
unchanged; release history and tags are preserved.

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
  `AudioToolbox`, `Metal` (VideoToolbox filters)

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

Builds and tests run on GitHub Actions `xcode-27` runners (macOS 27, Xcode 27.1,
iOS 27 SDK); the consumer check also runs on `xcode-27`.
There is no local Mac in the loop.

```
scripts/build-ffmpeg.sh       # configure + build per-arch, create 6 xcframeworks
scripts/verify.sh             # inspect slices, validate module maps, run a
                              #   simulator smoke test
scripts/package-sources.sh    # source archives, licence texts, build info
scripts/gen-package-swift.sh  # render Package.swift (release binaries, or
                              #   build/xcframeworks with LOCAL_XCFRAMEWORKS=1)
scripts/swift-test.sh         # build the package, run its tests on a simulator
scripts/release.sh            # pin Package.swift, tag, create the Release
.github/workflows/build.yml          # binaries
.github/workflows/swift-tests.yml    # Swift package, every branch
.github/workflows/consumer-check.yml # consumer app builds against the engine
```

- **Push to `main`** touching the build → builds, verifies, packages sources
  and licences, uploads everything as the `dist` workflow artifact, then
  builds the consumer app against those binaries.
- **Run the build workflow manually with a `release_tag`** → all of the
  above, then (only if the consumer built) regenerates `Package.swift` pinned to this
  build's SHA-256 checksums, commits it to `main`, tags that commit, creates
  the GitHub Release, and builds the consumer once more against the published tag.
- **Push touching `Sources/`, `Tests/` or `Package.swift`** (any branch) → the
  Swift tests workflow builds the package against the binaries `Package.swift`
  pins and runs its tests on an iOS simulator, without rebuilding FFmpeg.
- **Run the Swift tests workflow manually with a `release_tag`** → a Swift-only
  release: tests, the consumer check, then a tag whose `Package.swift` keeps the
  XCFrameworks of the release it already pins.

`Package.swift` is generated and follows the tree: after adding or removing a
target directory, run `bash scripts/gen-package-swift.sh > Package.swift`. The
Swift tests fail while the committed file differs from the generator's output.

The release is dispatch-driven (not tag-push-driven) on purpose: the tag is
created *after* the build, on the commit that already holds the matching
`Package.swift`, so a `v1.0.0` checkout resolves checksums that match the
release assets. A published tag is never moved, since consumers have resolved
its checksums; `force_overwrite` exists only to finish a half-published
release.

### Cut a release

```bash
# New binaries
gh workflow run "Build FFmpeg XCFrameworks" -f release_tag=v1.3.0 -f summary="..."
# Swift changes only, same binaries
gh workflow run "Swift tests" -f release_tag=v1.4.0 -f summary="..."
```

Releases from v1.3.0 carry:

| Asset | Contents |
|---|---|
| `lib*.xcframework.zip`, `checksums.txt` | the binaries (binary releases only) |
| `Package.swift` | the manifest the tag pins |
| `LICENSES.zip` | `NOTICE.txt` (attribution text for an app's About screen), every licence text, `BUILDINFO.txt` |
| `SOURCES.txt` | version, origin, commit and SHA-256 of each library's source |
| `*.tar.gz`, `*.tar.xz` | the exact sources the binaries were built from (binary releases only) |
| `BUILDINFO.txt` | Xcode, SDKs, minimum iOS, FFmpeg configure lines |

## License & attribution

The build scripts, configuration and Swift sources in this repo are MIT (see
[LICENSE](LICENSE)). The XCFramework **artifacts** contain:

| Component | Version | Licence |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) | n9.0.2 | LGPL-2.1-or-later |
| [dav1d](https://code.videolan.org/videolan/dav1d) | 1.5.4 | BSD-2-Clause |
| [FreeType](https://freetype.org) | 2.13.3 | FreeType License |
| [FriBiDi](https://github.com/fribidi/fribidi) | 1.0.18 | LGPL-2.1-or-later |
| [HarfBuzz](https://harfbuzz.github.io) | 11.5.1 | MIT |
| [libass](https://github.com/libass/libass) | 0.17.5 | ISC |
| [zimg](https://github.com/sekrit-twc/zimg) | release-3.0.6 | WTFPL |

FFmpeg is configured **without** `--enable-gpl` and **without** x264/x265, so
no GPL code is linked in; the smoke test fails any build whose
`avutil_license()` is not LGPL. `h264_videotoolbox` / `hevc_videotoolbox` are
Apple framework encoders and pull in no GPL.

An app that links these must show the attribution notice, ship the licence
texts and offer the corresponding source: `LICENSES.zip` of the release it
uses carries the first two, and its `NOTICE.txt` points at the release that
holds the sources. H.264/HEVC patent licensing is a separate matter from the
software licence.
