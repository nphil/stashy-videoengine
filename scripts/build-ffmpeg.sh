#!/usr/bin/env bash
# ===========================================================================
# build-ffmpeg.sh
#
# Cross-compiles a lean, LGPL-clean, VideoToolbox-enabled FFmpeg for iOS and
# packages 6 static-library XCFrameworks, each with an arm64 iOS-device slice
# and an arm64 iOS-simulator slice plus a clang module map so Swift can
# `import Libavcodec` etc.
#
# macOS-only: requires Xcode, xcrun, lipo, xcodebuild, ditto, shasum.
# Designed to run on a GitHub Actions `macos-15` runner.
#
# Tunables (env):
#   FFMPEG_VERSION   FFmpeg git tag to build      (default n7.1.5)
#   MIN_IOS_VERSION  Minimum deployment target    (default 15.0)
#   USE_CCACHE       Set to 1 to wrap clang in ccache (CI sets this)
# ===========================================================================
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-n7.1.5}"
MIN_IOS_VERSION="${MIN_IOS_VERSION:-15.0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT/ffmpeg"            # FFmpeg source checkout
BUILD_DIR="$ROOT/build"
SCRATCH="$BUILD_DIR/scratch"      # per-SDK out-of-tree build dirs
THIN="$BUILD_DIR/thin"           # per-SDK install prefixes
HEADERS="$BUILD_DIR/headers"     # per-lib headers + module.modulemap
OUT="$BUILD_DIR/xcframeworks"    # final .xcframework outputs
DIST="$BUILD_DIR/dist"           # zipped artifacts + checksums.txt

# The 6 libraries we ship. Order matters for link/dependency clarity.
LIBS=(libavutil libavcodec libavformat libavfilter libswscale libswresample)

# --- Lean component set (LGPL-minimal + VideoToolbox) ----------------------
ENCODERS="h264_videotoolbox,hevc_videotoolbox,aac"
DECODERS="h264,hevc,vp9,vp8,av1,mpeg4,mpeg2video,vc1,theora,aac,ac3,eac3,opus,vorbis,flac,mp3,pcm_s16le,pcm_s16be"
PARSERS="h264,hevc,vp9,vp8,av1,mpeg4video,aac,ac3,opus,vorbis,flac,mpegaudio"
DEMUXERS="matroska,mov,avi,flv,mpegts,asf,ogg,hls,aac,mp3,flac,wav"
MUXERS="mov,mp4,mpegts"
BSFS="h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc"
PROTOCOLS="file,pipe"
FILTERS="scale,format,aresample,anull,null"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Fetch FFmpeg source at the pinned tag (skipped if cached).
# ---------------------------------------------------------------------------
fetch_source() {
  if [ -d "$SRC_DIR/.git" ]; then
    log "FFmpeg source already present ($FFMPEG_VERSION) — skipping clone"
  else
    log "Cloning FFmpeg $FFMPEG_VERSION"
    git clone --depth 1 --branch "$FFMPEG_VERSION" \
      https://github.com/FFmpeg/FFmpeg.git "$SRC_DIR"
  fi
}

# ---------------------------------------------------------------------------
# 2. Configure + build + install one (sdk, arch=arm64) slice.
#    $1 = SDK (iphoneos | iphonesimulator)
#    $2 = min-version flag (-mios-version-min | -mios-simulator-version-min)
# ---------------------------------------------------------------------------
build_one() {
  local sdk="$1" minflag="$2"
  local prefix="$THIN/$sdk"
  local builddir="$SCRATCH/$sdk"

  local sysroot cc ar ranlib strip nm ccache_prefix=""
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  ar="$(xcrun --sdk "$sdk" -f ar)"
  ranlib="$(xcrun --sdk "$sdk" -f ranlib)"
  strip="$(xcrun --sdk "$sdk" -f strip)"
  nm="$(xcrun --sdk "$sdk" -f nm)"

  if [ "${USE_CCACHE:-}" = "1" ] && command -v ccache >/dev/null 2>&1; then
    ccache_prefix="ccache "
    log "Using ccache for $sdk"
  fi

  local flags="-arch arm64 ${minflag}=${MIN_IOS_VERSION}"

  rm -rf "$builddir"
  mkdir -p "$builddir" "$prefix"
  ( cd "$builddir" && "$SRC_DIR/configure" \
      --prefix="$prefix" \
      --enable-cross-compile \
      --target-os=darwin \
      --arch=arm64 \
      --sysroot="$sysroot" \
      --cc="${ccache_prefix}${cc}" \
      --ar="$ar" \
      --ranlib="$ranlib" \
      --strip="$strip" \
      --nm="$nm" \
      --extra-cflags="$flags" \
      --extra-ldflags="$flags" \
      --enable-static --disable-shared --enable-pic --enable-small \
      --disable-programs --disable-doc --disable-debug \
      --disable-gpl --disable-nonfree \
      --disable-bzlib --disable-iconv --disable-lzma \
      --enable-videotoolbox \
      --disable-everything \
      --enable-avcodec --enable-avformat --enable-avfilter \
      --enable-swscale --enable-swresample \
      --enable-encoder="$ENCODERS" \
      --enable-decoder="$DECODERS" \
      --enable-parser="$PARSERS" \
      --enable-demuxer="$DEMUXERS" \
      --enable-muxer="$MUXERS" \
      --enable-bsf="$BSFS" \
      --enable-protocol="$PROTOCOLS" \
      --enable-filter="$FILTERS" )

  log "Building $sdk slice"
  make -C "$builddir" -j"$(sysctl -n hw.ncpu)"
  make -C "$builddir" install

  log "EXTRALIBS for $sdk (system libs the consuming app must link):"
  grep -E '^EXTRALIBS' "$builddir/ffbuild/config.mak" || true
}

# ---------------------------------------------------------------------------
# 3. Package each library as an .xcframework with headers + a module map.
#
# IMPORTANT — module-map collision: when several static-library xcframeworks
# are consumed as SwiftPM binary targets, SwiftPM/Xcode FLATTENS every binary
# target's Headers/* into ONE shared include dir. Six files all named
# `module.modulemap` would clobber each other and only one `import LibX` would
# resolve. So we ship exactly ONE module map (in libavutil's xcframework) that
# declares ALL SIX modules; the other five xcframeworks ship headers only. At
# consume time the flattened dir holds {module.modulemap, libavutil/,
# libavcodec/, ...}, so every `umbrella "libX"` resolves and all six modules
# import. FFmpeg's double-quote cross-includes ("libavutil/...") resolve from
# the same flattened dir via -I.
# ---------------------------------------------------------------------------
write_combined_modulemap() {
  local out="$1" lib mod
  : > "$out"
  for lib in "${LIBS[@]}"; do
    mod="Lib${lib#lib}"                 # libavcodec -> Libavcodec
    cat >> "$out" <<EOF
module $mod [system] {
    umbrella "$lib"
    export *
    module * { export * }
}
EOF
  done
}

package_xcframeworks() {
  rm -rf "$HEADERS" "$OUT"
  mkdir -p "$HEADERS" "$OUT"

  local lib hdrdir
  for lib in "${LIBS[@]}"; do
    hdrdir="$HEADERS/$lib"
    mkdir -p "$hdrdir"
    # Each xcframework ships only its own lib's headers subdir.
    cp -R "$THIN/iphoneos/include/$lib" "$hdrdir/$lib"
    # Exactly one xcframework (libavutil) also carries the combined module map.
    if [ "$lib" = "libavutil" ]; then
      write_combined_modulemap "$hdrdir/module.modulemap"
    fi

    log "Creating $lib.xcframework"
    xcodebuild -create-xcframework \
      -library "$THIN/iphoneos/lib/$lib.a"          -headers "$hdrdir" \
      -library "$THIN/iphonesimulator/lib/$lib.a"   -headers "$hdrdir" \
      -output "$OUT/$lib.xcframework"
  done
}

# ---------------------------------------------------------------------------
# 4. Zip each xcframework and emit SHA-256 checksums.
# ---------------------------------------------------------------------------
package_dist() {
  rm -rf "$DIST"
  mkdir -p "$DIST"

  local lib
  for lib in "${LIBS[@]}"; do
    ( cd "$OUT" && ditto -c -k --keepParent \
        "$lib.xcframework" "$DIST/$lib.xcframework.zip" )
  done

  ( cd "$DIST" && shasum -a 256 *.xcframework.zip | tee checksums.txt )
  log "Artifacts written to $DIST"
}

main() {
  log "FFmpeg $FFMPEG_VERSION  |  min iOS $MIN_IOS_VERSION"
  fetch_source
  build_one iphoneos        -mios-version-min
  build_one iphonesimulator -mios-simulator-version-min
  package_xcframeworks
  package_dist
  log "Done. 6 xcframeworks + checksums.txt in build/dist/"
}

main "$@"
