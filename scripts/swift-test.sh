#!/usr/bin/env bash
# ===========================================================================
# swift-test.sh [--local]
#
# Builds the Swift package for an iOS simulator and runs every test target in
# Package.swift (a plain build while there are none).
#   default  first checks that the committed Package.swift is what
#            gen-package-swift.sh emits, then uses it as committed: the
#            binaries come from the release it pins
#   --local  swaps in a manifest pointing at build/xcframeworks, to test a
#            fresh build-ffmpeg.sh run before it is released
# The committed Package.swift is restored on exit.
# ===========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/swift-test"
cd "$ROOT"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

mkdir -p "$WORK"
cp Package.swift "$WORK/Package.swift.committed"
trap 'cp "$WORK/Package.swift.committed" "$ROOT/Package.swift"' EXIT

if [ "${1:-}" = "--local" ]; then
  log "Manifest against build/xcframeworks"
  LOCAL_XCFRAMEWORKS=1 bash scripts/gen-package-swift.sh > "$WORK/Package.swift.local"
  cp "$WORK/Package.swift.local" Package.swift
else
  log "Committed Package.swift matches the generator"
  bash scripts/gen-package-swift.sh > "$WORK/Package.swift.expected"
  diff -u Package.swift "$WORK/Package.swift.expected" \
    || die "Package.swift is stale; regenerate: bash scripts/gen-package-swift.sh > Package.swift"
fi

# Tests launched right after xcodebuild booted the simulator stalled for 5-40 s
# in 13 of 23 runs on the xcode-27 runner (2026-11), enough to trip the tests'
# I/O timeouts; launched two minutes or more after the boot, 4 runs of 4 were
# clean (slowest suite 1 s). Booting first lets the boot overlap package
# resolution and the build; the settle wait covers a build that ends sooner.
SETTLE_SECONDS=120
UDID="$(bash scripts/sim-udid.sh)"
log "Booting the simulator"
xcrun simctl boot "$UDID" 2>/dev/null || true   # already booted is fine
( xcrun simctl bootstatus "$UDID" -b >/dev/null && date +%s > "$WORK/booted-at" ) &
BOOTING=$!

# The scheme that builds every target and runs every test is named after the
# package (Xcode 27.1 lists only that one), or <package>-Package.
SCHEME="$(xcodebuild -list -json | python3 -c '
import json, re, sys
info = json.load(sys.stdin)
schemes = (info.get("workspace") or info.get("project") or {}).get("schemes", [])
package = re.search(r"Package\(\s*name:\s*\"([^\"]+)\"", open("Package.swift").read()).group(1)
for name in (package + "-Package", package):
    if name in schemes:
        print(name)
        sys.exit(0)
sys.exit("no scheme for package %s among %s" % (package, schemes))
')"
echo "scheme: $SCHEME"

log "Resolving packages"
attempt=1
until xcodebuild -resolvePackageDependencies -scheme "$SCHEME" -derivedDataPath "$WORK/DD"; do
  [ "$attempt" -lt 3 ] || die "package resolution failed 3 times"
  sleep $((attempt * 20))
  attempt=$((attempt + 1))
done

# Naming every test target makes xcodebuild fail when the scheme leaves one
# out, instead of passing with fewer tests run.
TESTS="$(python3 -c '
import re, sys
print(" ".join(re.findall(r"\.testTarget\(\s*name:\s*\"([^\"]+)\"", open("Package.swift").read())))
')"
if [ -n "$TESTS" ]; then
  ACTION="test"
  for t in $TESTS; do
    ACTION="$ACTION -only-testing:$t"
  done
else
  ACTION="build"
fi

xcb() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "$@" | xcbeautify
  else
    xcodebuild "$@"
  fi
}

log "xcodebuild build-for-testing -scheme $SCHEME"
xcb build-for-testing -scheme "$SCHEME" -destination "id=$UDID" -derivedDataPath "$WORK/DD"

wait "$BOOTING" || die "simulator $UDID did not boot"
settle=$(( $(cat "$WORK/booted-at") + SETTLE_SECONDS - $(date +%s) ))
if [ "$settle" -gt 0 ]; then
  log "Letting the simulator settle for $settle s"
  sleep "$settle"
fi

log "xcodebuild $ACTION -scheme $SCHEME"
xcb $ACTION -scheme "$SCHEME" -destination "id=$UDID" -derivedDataPath "$WORK/DD"
