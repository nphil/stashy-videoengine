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

log "Resolving packages"
attempt=1
until xcodebuild -resolvePackageDependencies -derivedDataPath "$WORK/DD"; do
  [ "$attempt" -lt 3 ] || die "package resolution failed 3 times"
  sleep $((attempt * 20))
  attempt=$((attempt + 1))
done

SCHEMES="$(xcodebuild -list -json | python3 -c '
import json, sys
data = json.load(sys.stdin)
print("\n".join((data.get("workspace") or data.get("project") or {}).get("schemes", [])))
')"
echo "schemes:"
printf '  %s\n' $SCHEMES
SCHEME=""
for s in $SCHEMES; do
  case "$s" in *-Package) SCHEME="$s" ;; esac
done
if [ -z "$SCHEME" ]; then
  for s in $SCHEMES; do
    case "$s" in FFmpeg) SCHEME="$s" ;; esac
  done
fi
[ -n "$SCHEME" ] || die "no package scheme to build"

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

UDID="$(bash scripts/sim-udid.sh)"
log "xcodebuild $ACTION -scheme $SCHEME"
if command -v xcbeautify >/dev/null 2>&1; then
  xcodebuild $ACTION -scheme "$SCHEME" -destination "id=$UDID" \
    -derivedDataPath "$WORK/DD" | xcbeautify
else
  xcodebuild $ACTION -scheme "$SCHEME" -destination "id=$UDID" \
    -derivedDataPath "$WORK/DD"
fi
