# VideoEngine

The Swift layer over the FFmpeg binaries, shared by Stashy and Marquee. Two
library products, both Swift 6 with strict concurrency, iOS 16 and later:

- **`LoopbackHLS`**: the 127.0.0.1 HTTP server, fragment index, playlists and
  WebVTT tracks. No FFmpeg dependency.
- **`VideoEngine`**: sources, probe, remux, transcode, subtitles, hardware
  facts and diagnostics. Depends on `LoopbackHLS` and the FFmpeg binaries.

The `FFmpeg` product (the raw `Libav*` modules) is unchanged. Apps pin the
package with `exactVersion`, because any public API change is a major version.

Threading: every public type is `Sendable`. Each FFmpeg run owns one dedicated
thread; state shared with callers sits behind `OSAllocatedUnfairLock`. Nothing
in the engine is `@MainActor`, and no call blocks the caller's thread.

## API

### Sources

`ByteRangeSource` is what FFmpeg reads through a custom `AVIOContext`; FFmpeg
never opens a network URL itself.

- `HTTPRangeSource(url:headers:knownLength:readAheadBytes:requestTimeout:maxAttempts:)`
  sends credentials as headers (`X-Plex-Token`, `ApiKey`), never in the URL.
  A reply counts only when it is 206 with a matching `Content-Range` (or 200
  from offset 0); a dropped connection is retried, then reported as an error,
  never as the end of the file. `knownLength` (Plex `Part.size`) saves the
  size lookup.
- `FileRangeSource(fileURL:)` reads local files.
- `ByteRangeSources.make(for:headers:readAheadBytes:)` picks one by scheme.

### Probe

`MediaProbe.probe(...)` returns `MediaInfo`: container, duration, streams with
codec, language, title and dispositions, and colour and HDR details (transfer,
primaries, mastering display, content light level, Dolby Vision record).

### Remux

`RemuxSession` plays what AVPlayer cannot open by copying the source into a
growing fragmented MP4 served as HLS on 127.0.0.1.

```swift
let session = RemuxSession(
    sourceFactory: { HTTPRangeSource(url: partURL, headers: ["X-Plex-Token": token], knownLength: part.size) },
    options: options, logger: logger
)
let url = try await session.start(at: resumeTime)   // master.m3u8
for await event in session.events { … }            // opened, headerWritten, timeline, progress, finished, failed, stopped
session.updatePlayhead(item.currentTime().seconds)   // paces production
let seekURL = try await session.seek(to: target)     // a new run; replace the item
session.stop()
```

- **Timeline.** Each run's output starts at its origin, the first copied
  timestamp minus the container start time, reported as `.timeline(origin:)`
  and `timelineOrigin`. A position `t` on the item is movie time `t + origin`:
  the app shows `t + origin` and seeks the new item to `target - origin`.
- **Segments** are sealed as each fragment closes, so the first listing
  follows the first keyframe interval. `EXT-X-TARGETDURATION` is fixed per run
  (at least 10, else the longest indexed keyframe gap).
- **Multivariant playlist** (`options.multivariantPlaylist`, on by default):
  `CODECS`, `RESOLUTION`, `FRAME-RATE`, `VIDEO-RANGE` (SDR, PQ, HLG) and
  `SUPPLEMENTAL-CODECS` for Dolby Vision 8.1/8.4, read from the init segment.
- **HEVC and Dolby Vision.** HEVC is written as `hvc1`. Profile 5 becomes
  `dvh1` with the record kept (or added from `dolbyVisionFallback`, for a
  server that reports the profile but the file lacks the box), colour left
  unspecified. Profile 8 with compatibility 1 or 4 keeps its record unless
  `dolbyVision = .baseLayerOnly`. Profile 7 is stripped to its HDR10 base
  layer. Any other record is dropped.
- **Audio** (`options.audio`, `AudioPolicy`): one stream, the viewer's pick
  (`preferredIndex`), else the default, else the first. Copied: AAC-LC with a
  channel configuration, explicit-SBR HE-AAC, AC-3, E-AC-3 (above 5.1 its core
  through `eac3_core`), FLAC and ALAC up to stereo, 96 kHz and 24 bits.
  Everything else is decoded, mixed down to 5.1(side) or stereo and encoded to
  AAC (192 kbit/s stereo, 384 kbit/s 5.1, `aac_at` where available). AC-3 and
  E-AC-3 copies use `delay_moov`. A copy that breaks the muxer before the first
  segment is retried once as a re-encode.
- **Subtitles.** Source subtitle streams are read alongside, never muxed. Text
  (SRT, ASS, WebVTT, mov_text) becomes WebVTT renditions of the multivariant
  playlist (`/subs/<n>/index.m3u8`, fixed 10 s slots, each listed once the
  producer is 5 s past it), offered by AVPlayer under their names.
  `options.sidecarSubtitles` adds downloaded text tracks. Picture subtitles
  (PGS, VobSub, DVB) decode to `SubtitleOverlayTrack`, which the app draws:
  `session.subtitleStreams[i].overlay?.bitmaps(at: movieTime)`.
  `SubtitleFile.read(fileURL:forcedOnly:)` reads sidecar files (.srt, .vtt,
  .ass, .smi, .sup).
- **Pacing.** Production pauses `paceLeadSeconds` ahead of the playhead for
  sources above `paceMinSourceBytes`. The remux thread runs at
  user-initiated until a segment is listed and 8 s are ready, then at utility.
- `RemuxSession.sweepStaleFiles(in:prefixes:)` removes temp files a killed
  process left behind; call it at launch.

### Transcode

`FileTranscoder` re-encodes a local file in one VideoToolbox pass;
`ChunkedTranscoder` works in chunks of about 20 s and resumes an interrupted
run. Both take `TranscodeSettings(codec:quality:maxLongEdge:bitrateOverride:)`
and report through `TranscodeObserver`.

### Hardware

- `HardwareDecodeProbe.shared.verdict(for: VideoStreamFacts)` answers
  `.hardware`, `.softwareOnly`, `.unsupported` or `.unknown` (simulator) by
  opening a VideoToolbox session that requires a hardware decoder. Verdicts are
  cached per codec, profile, level, size class and bit depth until the OS or
  device changes. Pass the container's `hvcC`/`avcC`/`av1C` record in
  `configurationAtoms`.
- `HardwareCapabilities` is one `Sendable` snapshot: decode and encode
  support, display (HDR eligibility, EDR headroom, frame rate, gamut, capture,
  external playback), power (thermal state, Low Power Mode, battery) and
  compute. `power.shouldShedOptionalWork` is true at `serious` heat or in Low
  Power Mode.
- `LiveHardwareCapabilityProvider(display:battery:)` reads the device; the
  closures run the UIKit and AVFoundation reads on the main actor, so the
  engine has no UIKit dependency. `snapshot()` at launch and at each playback
  start; `changes()` yields on heat, power and HDR eligibility changes.
  `FixedHardwareCapabilityProvider` serves tests and previews.

### Diagnostics

- `EngineLogger` carries engine events to the app's log; `.silent` drops them.
- `EngineDiagnostics.report()` returns the recent measured lines for a support
  screen or bug report: `perf-remux` (start-up stages per run), `perf-run`
  (bytes, segments, lead, free memory, thermal state per run), `hw-id` to
  `hw-eng` (first snapshot), `hw-state` (on change) and `hw-probe` (per probe).
- Each stage is also an `os_signpost` interval, subsystem `VideoEngine`,
  category `stages`, for Instruments.

### Duties left to the app

- No permanent `AVPlayerItemVideoOutput`: attach one only for a feature that
  needs pixels and remove it on pause, in the background and from `fair` heat.
  A 32BGRA output at 4K copies about 33 MB per frame, 1 GB/s at 30 fps.
- Choose the route (direct play, remux, server transcode) from the probe, the
  decode verdict and the snapshot: an HDR or Dolby Vision source on a display
  that is not HDR-eligible goes to the server.

## Adoption

### Stashy

| Step | Change | Gate |
|---|---|---|
| a | `ios/project.yml`: package pinned with `exactVersion`; add `product: VideoEngine` beside `FFmpeg` | CI |
| b | `ScenePlayerModel`: `localStream` becomes `RemuxSession?`; the pre-remux probe goes; builders use `RemuxSession(sourceFactory:)` with the Stash `ApiKey` header; `OrientationLock` calls `RemuxSession.sweepStaleFiles`; delete `FFmpegRemuxer`, `FFmpegSource`, `FMP4Index`, `LocalRemuxStream`, `LoopbackServer`, `DeviceCapabilities`, `VideoTranscoder` and add the import | device |
| c | `EngineAdapters.swift`: wrap `FileTranscoder` and `ChunkedTranscoder` as the app's on-device transcoder; forward `EngineLogger` to `RemoteLog.shared`; `DownloadManager` call sites unchanged | device |
| d, e | drop the `FFmpeg` product and leftover `Libav*` imports; update `CLAUDE.md`, `ENGINEERING_NOTES.md`, `ROADMAP.md` | CI |

Seek handling changes with the timeline contract: after `seek(to:)` the new
item starts at the run's origin, so the scrubber shows `t + origin`.
`DeviceCapabilities.av1HardwareDecode` becomes
`snapshot().decode.av1 == .hardware`.

### Marquee (step M)

`product: VideoEngine` with `exactVersion` in its XcodeGen file;
`HTTPRangeSource` with `X-Plex-Token` as a header and `knownLength` from
`Part.size`; its own `EngineLogger`; the About screen lists FFmpeg and its
licence. The Info.plist needs `NSAllowsLocalNetworking` for LAN `http://<ip>:32400`.

## Device test sheets

The simulator runs neither VideoToolbox nor AVPlayer playback, so these run on
a real iPhone (iOS 27, unplugged, Low Power Mode off, thermal nominal unless a
row says otherwise). Each accepted row records device, iOS build, fixture and
the receipt path (screenshot, video or `EngineDiagnostics.report()` text).

### Start and seek (performance)

| ID | Steps | Pass | Log |
|---|---|---|---|
| P1 | 1080p H.264 MKV, 4K HDR10 MKV (1 s and 10 s keyframes), Cues at end and none: 5 cold starts each | first frame within one keyframe interval of `playlist_ready` | `perf-remux` |
| P2 | 5 far seeks (10, 25, 50, 75, 90 %) and 3 near seeks per item | landing within 0.5 s of the target; the shown time includes the origin | `perf-remux`, `remux-start` |
| P3 | 10-minute play of the 4K item | no stall; thermal at most `fair`; `perf-run` lead stays positive | `perf-run` |
| P4 | Instruments or Console with subsystem `VideoEngine` | `open`, `find_stream_info`, `first_packet`, `first_fragment`, `playlist_ready` present per run | signposts |

### Hardware

| ID | Steps | Pass | Log |
|---|---|---|---|
| H1 | Settings, Developer, Hardware report, Share | every `hw-*` group present, `machine=iPhoneNN,N`, under 3.8 KB | `hw-id` to `hw-eng` |
| H2 | the HDR sheet below plus VP9, MPEG-2 1080i, VC-1, HEVC 4:2:2, HEVC 4:4:4, Hi10P H.264, AV1 10-bit | verdict agrees with AVPlayer showing a first frame within 5 s; no `hardware` verdict that then fails | `hw-probe` |
| H3 | an A16-class and an A17 Pro-or-newer phone; AV1 8 and 10-bit 1080p | A16: `av1=no`, routed to the server; A17 Pro: `av1=hw`, plays directly | `hw-probe` |
| H4 | Low Power Mode on, then a 10-minute 4K play until `serious` heat | `hw-state` lines follow; optional work stops | `hw-state` |

### HDR and Dolby Vision

| # | Clip | Expected |
|---|---|---|
| F1 / F2 | HDR10 MKV 4K24 with mastering and CLL / the same as MP4 `hvc1` | HDR; init segment `hvc1`, `colr` 9/16/9, `mdcv`, `clli`; same look |
| F3 / F4 | HLG MKV / HDR10+ MKV | HLG (`colr` 9/18/9) / HDR10 |
| F5 / F6 | DV P5 MKV with `dvcC` / without (server-reported record via `dolbyVisionFallback`) | `dvh1`, correct colours, no decoder error; F6 = F5 |
| F7 / F8 / F9 | DV P7 MEL / FEL single-track / dual-track MKV | HDR10 base layer, no stutter; dual-track copies the base layer only |
| F10 / F11 | DV P8.1 MKV / P8.4 (iPhone .MOV remuxed to MKV) | Dolby Vision with HDR10 fallback; `SUPPLEMENTAL-CODECS` in the master |
| F12 | 4K60 10-bit HDR10, level 5.1 | smooth, no decoder error |

Per clip: check the master's `VIDEO-RANGE` and `CODECS`, watch
`AVPlayerItem.error` (-11833, -12906), see `currentEDRHeadroom` rise above 1
while playing, then seek twice.

### Audio

| ID | Steps | Pass |
|---|---|---|
| T1 | AC-3 5.1 copy | plays from the first segment (`delay_moov`); lip sync within 40 ms on the flash-and-beep clip |
| T2 | E-AC-3 5.1 and JOC on AirPods Pro | Atmos engages for JOC |
| T3 | E-AC-3 7.1 | the 5.1 core plays; compare with an AAC re-encode |
| T4 | TrueHD and DTS family with one tone per channel | AAC 5.1: each tone on its speaker, no clipping |
| T5 / T6 | FLAC/ALAC stereo copy; MP3, Opus, Vorbis, MP2 re-encode | plays; record any silence or error |
| T7 | AAC-LC, HE-AAC, AAC with a program config element | the first two copy, the third re-encodes; all play |

### Subtitles

| ID | Steps | Pass |
|---|---|---|
| S1 | MKV with SRT en/fr and forced SRT: cues at 10 s, 10 min, 60 min | within 100 ms of mpv |
| S2 | 10 seeks, including past the produced range and to a non-keyframe | right cue within 0.5 s, no duplicates |
| S3 | track names, languages and flags in the app and in `AVPlayerViewController` | names as listed by `subtitleStreams`; selection survives a seek restart; system caption style applies |
| S4 | Picture in Picture | WebVTT visible; picture overlays absent |
| S5 | styled ASS | italics and bold kept, positioning dropped, drawings absent |
| S6 | PGS (1080p canvas on 2160p video) and BD `.m2ts` | placement in both orientations, forced-only, pause, 2x, seek |
| S7 | MKV VobSub with and without palette | pictures shown; none without a palette |
| S8 | a 12 s GOP file with long cues | long cues repeat across slots without flicker; the subtitle playlist may trail the video |
| S9 | AirPlay with the loopback URL | expected unreachable: the app falls back |
