#!/usr/bin/env bash
# ===========================================================================
# release.sh <tag>
#
# Run by the release jobs (build.yml, swift-tests.yml) on a workflow_dispatch
# with release_tag set, after the build, the tests and the consumer
# check passed. It:
#   1. regenerates Package.swift pinned to the release's binaries,
#   2. commits that manifest and pushes it to main,
#   3. tags that commit and pushes the tag,
#   4. creates the GitHub Release with the assets.
#
# Binaries release (default): build/dist holds this run's build; every file in
# it is attached (six zips, checksums.txt, LICENSES.zip, SOURCES.txt,
# BUILDINFO.txt, source archives).
# Swift-only release (REUSE_BINARIES=1): Package.swift keeps the XCFrameworks
# of the release it already pins; that release's LICENSES.zip, SOURCES.txt and
# BUILDINFO.txt are attached again so every release carries its notices.
#
# Tagging AFTER the manifest commit is the point: builds are not
# byte-reproducible, so only a manifest written after the build can pin its
# checksums, and the tag must land on the commit that holds it.
#
# A tag that exists is never moved: consumers have resolved its checksums.
# FORCE=1 overwrites a tag and its assets deliberately (a half-finished
# release). SUMMARY opens the release notes.
#
# Requires: GH_TOKEN with contents:write; a checkout of main.
# ===========================================================================
set -euo pipefail

TAG="${1:?usage: release.sh <tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/build/dist"
WORK="$ROOT/build/release"
REPO="${REPO:-nphil/videoengine}"
FORCE="${FORCE:-0}"
REUSE="${REUSE_BINARIES:-0}"
NOTICES="LICENSES.zip SOURCES.txt BUILDINFO.txt"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must look like v1.2.3, got $TAG"
cd "$ROOT"

set +e
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null
rc=$?
set -e
case "$rc" in
  0) [ "$FORCE" = "1" ] \
       || die "tag $TAG exists and consumers pin its checksums; cut a new tag (FORCE=1 overwrites)" ;;
  2) ;;
  *) die "could not list tags on origin (git ls-remote exit $rc)" ;;
esac

git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse FETCH_HEAD)" ] \
  || die "main moved since this run started; dispatch the release again"

rm -rf "$WORK"
mkdir -p "$WORK"
ASSETS="$WORK/assets"
if [ "$REUSE" = "1" ]; then
  BINARIES_TAG="$(bash scripts/gen-package-swift.sh --pinned-tag)"
  [ "$BINARIES_TAG" != "$TAG" ] || die "Package.swift already pins $TAG"
  log "Swift-only release $TAG on the binaries of $BINARIES_TAG"
  mkdir -p "$ASSETS"
  for a in $NOTICES; do
    curl -fsSL --retry 3 --retry-delay 2 -o "$ASSETS/$a" \
      "https://github.com/$REPO/releases/download/$BINARIES_TAG/$a" \
      || die "$BINARIES_TAG has no $a; Swift-only releases need binaries from v1.3.0 or later"
  done
else
  BINARIES_TAG="$TAG"
  log "Binaries release $TAG"
  for a in checksums.txt $NOTICES; do
    [ -s "$DIST/$a" ] || die "build/dist/$a missing; download this run's dist artifact first"
  done
  cp -R "$DIST" "$ASSETS"
fi
export BINARIES_TAG

log "Pinning Package.swift"
bash scripts/gen-package-swift.sh "$TAG" > "$WORK/Package.swift"
cp "$WORK/Package.swift" Package.swift
cp "$WORK/Package.swift" "$ASSETS/Package.swift"
git diff --stat -- Package.swift

info() { sed -n "s/^$1: //p" "$ASSETS/BUILDINFO.txt"; }
FFMPEG="$(info ffmpeg | cut -d' ' -f1)"
{
  [ -z "${SUMMARY:-}" ] || printf '%s\n\n' "$SUMMARY"
  echo "FFmpeg $FFMPEG ($(info license)) XCFrameworks for iOS, arm64 device and simulator."
  echo "Built with $(info xcode), iOS SDK $(info iphoneos_sdk), minimum iOS $(info min_ios)."
  if [ "$REUSE" = "1" ]; then
    echo "Swift-only release: the XCFrameworks are those of $BINARIES_TAG, unchanged."
  fi
  echo
  echo "LICENSES.zip holds the attribution notice and every licence text; SOURCES.txt"
  echo "lists the corresponding source, attached to $BINARIES_TAG."
} > "$WORK/notes.md"
cat "$WORK/notes.md"

log "Committing the manifest and tagging $TAG"
BOT=(-c "user.name=github-actions[bot]" -c "user.email=41898282+github-actions[bot]@users.noreply.github.com")
git add Package.swift
if git diff --cached --quiet; then
  echo "Package.swift already pinned; tagging the current commit."
else
  git "${BOT[@]}" commit -q -m "release $TAG: pin Package.swift to release checksums [skip ci]"
fi
if [ "$FORCE" = "1" ]; then TAG_FORCE="-f"; else TAG_FORCE=""; fi
git "${BOT[@]}" tag $TAG_FORCE -a "$TAG" -m "videoengine $TAG (FFmpeg $FFMPEG, binaries $BINARIES_TAG)"
# Pushes made with the workflow token start no further workflow runs.
git push origin HEAD:main
git push $TAG_FORCE origin "refs/tags/$TAG"

log "Creating GitHub Release $TAG"
if [ "$FORCE" = "1" ] && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" --repo "$REPO" --clobber "$ASSETS"/*
  gh release edit "$TAG" --repo "$REPO" --notes-file "$WORK/notes.md"
else
  gh release create "$TAG" --repo "$REPO" --verify-tag --title "$TAG" \
    --notes-file "$WORK/notes.md" "$ASSETS"/*
fi

log "Release $TAG complete: https://github.com/$REPO/releases/tag/$TAG"
