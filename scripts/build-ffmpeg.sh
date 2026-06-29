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
DEPS="$BUILD_DIR/deps"           # external-lib install prefixes (per sdk; cacheable)
EXTSRC="$BUILD_DIR/extsrc"       # external-lib source checkouts (per sdk)

# The 6 libraries we ship. Order matters for link/dependency clarity.
LIBS=(libavutil libavcodec libavformat libavfilter libswscale libswresample)

# Comprehensive LGPL build (v1.1.0+). Rather than an allow-list, we build the
# FULL non-GPL component set: ALL built-in filters (incl. the VideoToolbox
# hardware filters scale_vt/transpose_vt/yadif_vt/tonemap_vt), all built-in
# decoders/demuxers/muxers/parsers/bsfs, plus the external-library filters
# (zscale via libzimg; drawtext via libfreetype+libharfbuzz+libfribidi;
# subtitles/ass via libass). GPL stays OFF (no --enable-gpl, no postproc, no
# x264/x265), so this is LGPL-clean. Static dead-strip means the consuming app
# only links the components it actually calls — a large catalog here does not
# bloat the app; it just means the app never needs another FFmpeg rebuild.

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
  local depprefix="$DEPS/$sdk"

  # Cross-compile the external libraries (drawtext/subtitles/zscale) into a
  # per-sdk prefix; FFmpeg finds them via pkg-config below. Skipped per-lib if
  # already installed (a cached $DEPS makes this a near no-op).
  bash "$ROOT/scripts/build-deps.sh" "$sdk" "$depprefix" "$EXTSRC/$sdk" "$MIN_IOS_VERSION"

  rm -rf "$builddir"
  mkdir -p "$builddir" "$prefix"
  ( cd "$builddir" && PKG_CONFIG_LIBDIR="$depprefix/lib/pkgconfig" "$SRC_DIR/configure" \
      --prefix="$prefix" \
      --enable-cross-compile \
      --target-os=darwin \
      --arch=arm64 \
      --sysroot="$sysroot" \
      --cc="${ccache_prefix}${cc}" \
      --cxx="$(xcrun --sdk "$sdk" -f clang++)" \
      --ar="$ar" \
      --ranlib="$ranlib" \
      --strip="$strip" \
      --nm="$nm" \
      --pkg-config="pkg-config" \
      --pkg-config-flags="--static" \
      --extra-cflags="$flags -I$depprefix/include" \
      --extra-ldflags="$flags -L$depprefix/lib" \
      --extra-libs="-lc++" \
      --enable-static --disable-shared --enable-pic --enable-small \
      --disable-programs --disable-doc --disable-debug \
      --disable-gpl --disable-nonfree \
      --disable-postproc --disable-avdevice \
      --disable-lzma \
      --enable-videotoolbox \
      --enable-securetransport \
      --enable-libfribidi --enable-libfreetype --enable-libharfbuzz \
      --enable-libzimg --enable-libass \
      --enable-encoder=h264_videotoolbox,hevc_videotoolbox )

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

# FFmpeg installs the hwaccel public headers for EVERY backend (cuda, d3d11va,
# vaapi, vdpau, qsv, vulkan, opencl, ...) regardless of what was enabled, and
# each one #includes an external SDK header (cuda.h, d3d11.h, va/va.h, ...)
# that does not exist on iOS. Our umbrella module would try to compile them and
# fail. Drop the ones irrelevant to iOS; keep the core hwcontext.h and the
# VideoToolbox variants (those only pull in system frameworks).
prune_unavailable_headers() {
  local d="$1"
  if [ -d "$d/libavutil" ]; then
    find "$d/libavutil" -name 'hwcontext_*.h' ! -name 'hwcontext_videotoolbox.h' -delete
  fi
  if [ -d "$d/libavcodec" ]; then
    local h
    for h in dxva2.h d3d11va.h d3d12va.h qsv.h vdpau.h vaapi.h mediacodec.h; do
      rm -f "$d/libavcodec/$h"
    done
  fi
}

# The external libraries (libass/libzimg/libharfbuzz/libfreetype/libfribidi)
# are separate static archives, but only libavfilter references them (drawtext,
# subtitles, zscale). Merge them INTO each slice's libavfilter.a so the shipped
# xcframework is self-contained — the consuming app links no extra archives,
# only the libc++ runtime. Use Apple's libtool via xcrun (NOT the GNU libtool
# that `brew install libtool` puts on PATH, which has no -static merge).
merge_external_libs() {
  local sdk d e
  for sdk in iphoneos iphonesimulator; do
    d="$THIN/$sdk/lib"
    e="$DEPS/$sdk/lib"
    log "Merging external libs into libavfilter.a ($sdk)"
    xcrun libtool -static -o "$d/libavfilter-merged.a" \
      "$d/libavfilter.a" \
      "$e/libass.a" "$e/libzimg.a" "$e/libharfbuzz.a" \
      "$e/libfreetype.a" "$e/libfribidi.a"
    mv "$d/libavfilter-merged.a" "$d/libavfilter.a"
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
    prune_unavailable_headers "$hdrdir"
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
  merge_external_libs
  package_xcframeworks
  package_dist
  log "Done. 6 xcframeworks + checksums.txt in build/dist/"
}

main "$@"
