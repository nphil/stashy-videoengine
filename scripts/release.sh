#!/usr/bin/env bash
# ===========================================================================
# release.sh <tag>
#
# Run from the build job on a workflow_dispatch with a release_tag input, AFTER
# build + verify have produced build/dist/. It:
#   1. regenerates Package.swift pinned to this build's checksums,
#   2. commits that manifest and pushes it to main,
#   3. creates/moves the tag to that commit and pushes it,
#   4. creates (or updates) the GitHub Release with the zips + checksums.
#
# Doing the tag AFTER the manifest commit is the whole point: a tag-triggered
# build can't pin checksums (it runs after the tag is placed, and builds aren't
# byte-reproducible). Here the tag ends up on the commit that already contains
# the correct Package.swift, so SwiftPM consumers resolve a matching manifest.
#
# Requires: GH_TOKEN in the environment (github.token); contents:write.
# ===========================================================================
set -euo pipefail

TAG="${1:?usage: release.sh <tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/build/dist"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "Regenerating Package.swift for $TAG"
bash "$ROOT/scripts/gen-package-swift.sh" "$TAG" > "$ROOT/Package.swift"

log "Committing pinned manifest and tagging $TAG"
git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Package.swift
git commit -m "release $TAG: pin Package.swift to release checksums [skip ci]" \
  || echo "Package.swift unchanged — committing nothing new."
git tag -f -a "$TAG" -m "FFmpeg ${FFMPEG_VERSION:-} XCFrameworks $TAG"

# Push the manifest commit to main, then the tag pointing at it. Pushes made
# with the default token do not trigger another workflow run.
git push origin HEAD:main \
  || echo "WARN: push to main rejected (main moved); the tag + release still carry the manifest."
git push -f origin "refs/tags/$TAG"

log "Creating GitHub Release $TAG"
cp "$ROOT/Package.swift" "$DIST/Package.swift"
notes="FFmpeg ${FFMPEG_VERSION:-} XCFrameworks for iOS (arm64 device + arm64 simulator).

LGPL v2.1+ — no GPL, no x264/x265. Hardware encode via h264_videotoolbox /
hevc_videotoolbox + native AAC. See README for how to consume these.

SHA-256 checksums are in checksums.txt and pinned in Package.swift."

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DIST"/*.xcframework.zip "$DIST/checksums.txt" "$DIST/Package.swift" --clobber
else
  gh release create "$TAG" \
    "$DIST"/*.xcframework.zip "$DIST/checksums.txt" "$DIST/Package.swift" \
    --title "$TAG" --notes "$notes"
fi

log "Release $TAG complete"
