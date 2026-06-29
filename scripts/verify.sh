#!/usr/bin/env bash
# ===========================================================================
# verify.sh
#
# Post-build gates that run natively on the runner. Every step is a hard fail.
#   1. Each .xcframework exposes ios-arm64 + ios-arm64-simulator (arm64).
#   2. The VideoToolbox encoders are actually compiled into libavcodec.
#   3. Module maps validate under the REAL consume layout: all six
#      xcframeworks' Headers are flattened into one include dir (exactly what
#      SwiftPM does for binary targets), then both ObjC `@import` and Swift
#      `import` of all six modules must compile. This reproduces the
#      module.modulemap collision / cross-include failures that a naive
#      per-library -I check would hide.
#   4. A tiny C program links every lib + the system frameworks and runs on an
#      iOS simulator, confirming av_version_info() and that the VideoToolbox
#      encoders are registered at runtime.
# ===========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
OUT="$BUILD_DIR/xcframeworks"
THIN="$BUILD_DIR/thin"
TESTDIR="$ROOT/test"
WORK="$BUILD_DIR/verify"
MIN_IOS_VERSION="${MIN_IOS_VERSION:-16.0}"
SIM_TRIPLE="arm64-apple-ios${MIN_IOS_VERSION}-simulator"

LIBS=(libavutil libavcodec libavformat libavfilter libswscale libswresample)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
pass() { printf '\033[1;32m  [PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  [FAIL]\033[0m %s\n' "$*"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

# --- 1: structure + architecture ------------------------------------------
log "Inspecting xcframeworks"
for lib in "${LIBS[@]}"; do
  fw="$OUT/$lib.xcframework"
  [ -d "$fw" ] || fail "$lib.xcframework missing"
  ids="$(plutil -p "$fw/Info.plist" | grep -o '"LibraryIdentifier" => "[^"]*"' | sed 's/.*=> "//;s/"//')"
  echo "$ids" | grep -q '^ios-arm64$'           || fail "$lib missing ios-arm64 slice"
  echo "$ids" | grep -q '^ios-arm64-simulator$' || fail "$lib missing ios-arm64-simulator slice"
  lipo -info "$fw/ios-arm64/$lib.a"           | grep -q 'arm64' || fail "$lib device not arm64"
  lipo -info "$fw/ios-arm64-simulator/$lib.a" | grep -q 'arm64' || fail "$lib simulator not arm64"
  pass "$lib.xcframework: ios-arm64 + ios-arm64-simulator (arm64)"
done

# --- 2: VideoToolbox encoders present in the binary -----------------------
# NB: capture nm's (large) output into a variable and match with `case` rather
# than `nm | grep -q`. Under `set -o pipefail`, grep -q closes the pipe on its
# first match, nm dies with SIGPIPE (141), and pipefail would report the whole
# pipeline as failed even though the symbol WAS found.
log "Checking compiled-in encoders/decoders (nm, device slice)"
codec="$THIN/iphoneos/lib/libavcodec.a"
codec_syms="$(xcrun nm "$codec" 2>/dev/null || true)"
for sym in ff_h264_videotoolbox_encoder ff_hevc_videotoolbox_encoder \
           ff_prores_videotoolbox_encoder ff_aac_encoder \
           ff_libdav1d_decoder ff_pgssub_decoder ff_dvdsub_decoder ff_dvbsub_decoder; do
  case "$codec_syms" in
    *"$sym"*) pass "$sym present" ;;
    *) echo "  encoder/decoder-ish symbols present in libavcodec.a:"
       printf '%s\n' "$codec_syms" | grep -iE 'videotoolbox|aac_encoder|dav1d|pgssub|dvdsub|dvbsub' | head -20 || true
       fail "symbol $sym not found in libavcodec.a" ;;
  esac
done
# Confirm libdav1d.a actually got merged INTO libavcodec.a (not just the FFmpeg
# wrapper object) — the dav1d implementation symbols must resolve in-archive, or
# the consuming app link fails with undefined _dav1d_*.
case "$codec_syms" in
  *dav1d_open*) pass "dav1d implementation merged into libavcodec.a" ;;
  *) fail "dav1d_open absent from libavcodec.a — libdav1d merge missing (app link would fail)" ;;
esac

# The VideoToolbox hardware scale/rotate filters need iOS-16 APIs; confirm the
# min-iOS-16 build actually compiled them into the device slice's libavfilter.
log "Checking compiled-in VideoToolbox filters (nm, device slice)"
filt="$THIN/iphoneos/lib/libavfilter.a"
filt_syms="$(xcrun nm "$filt" 2>/dev/null || true)"
for sym in ff_vf_scale_vt ff_vf_transpose_vt ff_vf_yadif_videotoolbox; do
  case "$filt_syms" in
    *"$sym"*) pass "$sym present" ;;
    *) echo "  *_vt / _videotoolbox filter symbols present in libavfilter.a:"
       printf '%s\n' "$filt_syms" | grep -iE '_vt|videotoolbox' | head -20 || true
       fail "filter symbol $sym not found in libavfilter.a (min iOS 16 should enable scale_vt/transpose_vt)" ;;
  esac
done

# --- 3: module maps under the flattened consume layout --------------------
log "Flattening all six xcframeworks' Headers into one include dir (as SwiftPM does)"
FLAT="$WORK/flat-include"
mkdir -p "$FLAT"
for lib in "${LIBS[@]}"; do
  cp -R "$OUT/$lib.xcframework/ios-arm64-simulator/Headers/." "$FLAT/"
done
[ -f "$FLAT/module.modulemap" ] || fail "no module.modulemap in flattened include dir"
echo "  flattened contents: $(ls "$FLAT" | tr '\n' ' ')"

log "ObjC @import of all six modules (clang -fmodules)"
xcrun --sdk iphonesimulator clang -target "$SIM_TRIPLE" \
  -fmodules -fsyntax-only \
  -I "$FLAT" -fmodules-cache-path="$WORK/modcache" \
  "$TESTDIR/module_check.m" \
  && pass "all 6 modules @import cleanly" \
  || fail "module map / @import validation failed"

log "Swift import of all six modules (swiftc -typecheck)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -target "$SIM_TRIPLE" -sdk "$SIM_SDK" \
  -typecheck \
  -Xcc -I -Xcc "$FLAT" \
  "$TESTDIR/SwiftImportCheck.swift" \
  && pass "all 6 modules import from Swift" \
  || fail "Swift import validation failed"

# --- 4: link + run on a simulator -----------------------------------------
log "Compiling + linking simulator smoke test"
xcrun --sdk iphonesimulator clang -target "$SIM_TRIPLE" \
  "$TESTDIR/smoke.c" \
  -I "$THIN/iphonesimulator/include" \
  -L "$THIN/iphonesimulator/lib" \
  -lavformat -lavfilter -lavcodec -lswscale -lswresample -lavutil \
  -lz -lbz2 -liconv -lc++ \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -framework CoreFoundation -framework Security -framework AudioToolbox \
  -framework Metal \
  -o "$WORK/smoke" \
  && pass "smoke test linked" \
  || fail "smoke test failed to link"

log "Selecting an available simulator and running the smoke test"
# Use a simulator the runner already pre-created (guaranteed device/runtime
# compatibility) rather than pairing an arbitrary device type with the latest
# runtime, which can yield SimError 403 "Incompatible device".
UDID="$(xcrun simctl list devices available -j | python3 -c '
import sys, json
data = json.load(sys.stdin)["devices"]
for runtime, devs in data.items():
    if "iOS" not in runtime:
        continue
    for dev in devs:
        if dev.get("isAvailable") and "iPhone" in dev.get("name", ""):
            print(dev["udid"]); sys.exit(0)
')"
[ -n "$UDID" ] || fail "no available iOS simulator found on the runner"
echo "  using simulator udid: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" >/dev/null 2>&1 || true
trap 'xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true' EXIT
xcrun simctl spawn "$UDID" "$WORK/smoke" && pass "smoke test ran on simulator" \
  || fail "smoke test returned non-zero on simulator"

log "All verification checks passed"
