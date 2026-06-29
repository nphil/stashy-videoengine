#!/usr/bin/env bash
# ===========================================================================
# release.sh <tag>
#
# Run from the build job on a tag push. Creates (or updates) the GitHub
# Release for <tag>, attaches the 6 zipped xcframeworks + checksums.txt,
# regenerates Package.swift pinned to those assets, and pushes it to main.
#
# Requires: GH_TOKEN in the environment (github.token).
# ===========================================================================
set -euo pipefail

TAG="${1:?usage: release.sh <tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/build/dist"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "Regenerating Package.swift for $TAG"
bash "$ROOT/scripts/gen-package-swift.sh" "$TAG" > "$ROOT/Package.swift"

log "Creating GitHub Release $TAG"
notes="FFmpeg ${FFMPEG_VERSION:-} XCFrameworks for iOS (arm64 device + arm64 simulator).

LGPL v2.1+ — no GPL, no x264/x265. Hardware encode via h264_videotoolbox /
hevc_videotoolbox + native AAC. See README for how to consume these.

SHA-256 checksums are in checksums.txt and pinned in Package.swift."

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DIST"/*.xcframework.zip "$DIST/checksums.txt" --clobber
else
  gh release create "$TAG" \
    "$DIST"/*.xcframework.zip "$DIST/checksums.txt" \
    --title "$TAG" --notes "$notes"
fi

# Attach the freshly generated manifest as a release asset too (handy if the
# back-push to main is rejected because main moved on).
cp "$ROOT/Package.swift" "$DIST/Package.swift"
gh release upload "$TAG" "$DIST/Package.swift" --clobber || true

log "Pushing updated Package.swift to main"
git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Package.swift
if git diff --cached --quiet; then
  echo "Package.swift unchanged."
else
  git commit -m "chore: pin Package.swift to $TAG [skip ci]"
  git push origin HEAD:main || echo "WARN: back-push to main rejected (main moved); manifest is attached to the release."
fi

log "Release $TAG complete"
