#!/usr/bin/env bash
# ===========================================================================
# package-sources.sh
#
# Run after build-ffmpeg.sh. Adds to build/dist what LGPL-2.1 section 6 and
# the bundled libraries' licences require to travel with the binaries:
#   <name>-<version>.tar.*  the exact source each library was built from
#   SOURCES.txt             version, origin, commit and SHA-256 per archive
#   LICENSES.zip            NOTICE.txt (attribution text for an About screen),
#                           every licence text and BUILDINFO.txt
#   BUILDINFO.txt           toolchain, SDKs, minimum iOS, configure lines
# RELEASE_TAG, set by a release run, names the release in the notices.
# ===========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
DIST="$BUILD_DIR/dist"
SRC_DIR="$ROOT/ffmpeg"
ARCHIVES="$BUILD_DIR/deps/sources"   # filled by build-deps.sh
LIC="$BUILD_DIR/licenses/LICENSES"
REPO="${REPO:-nphil/stashy-videoengine}"
RELEASE_TAG="${RELEASE_TAG:-}"

# Every bundled library: display name | licence | licence files in its source.
LIBRARIES="dav1d freetype fribidi harfbuzz libass zimg"
license_of() {
  case "$1" in
    dav1d)    echo "dav1d|BSD-2-Clause|COPYING" ;;
    freetype) echo "FreeType|FreeType License|LICENSE.TXT docs/FTL.TXT" ;;
    fribidi)  echo "FriBiDi|LGPL-2.1-or-later|COPYING" ;;
    harfbuzz) echo "HarfBuzz|MIT|COPYING" ;;
    libass)   echo "libass|ISC|COPYING" ;;
    zimg)     echo "zimg|WTFPL|COPYING" ;;
    *) return 1 ;;
  esac
}

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ -d "$DIST" ] || die "no build/dist; run build-ffmpeg.sh first"
for f in "$ARCHIVES"/*.source; do
  [ -f "$f" ] || die "no source records in $ARCHIVES"
  license_of "$(basename "$f" .source)" >/dev/null \
    || die "$(basename "$f" .source) has no licence entry in package-sources.sh"
done

FFMPEG_VERSION="$(sed -n 's/^#define FFMPEG_VERSION "\(.*\)"$/\1/p' \
  "$BUILD_DIR/thin/iphoneos/include/libavutil/ffversion.h")"
[ -n "$FFMPEG_VERSION" ] || die "no FFmpeg version in the build; run build-ffmpeg.sh first"
[ -z "$(git -C "$SRC_DIR" status --porcelain)" ] \
  || die "the FFmpeg checkout has local changes; its archive would not match the build"
FFMPEG_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
ENGINE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
if [ -n "$RELEASE_TAG" ]; then
  WHERE="release $RELEASE_TAG"
  WHERE_URL="https://github.com/$REPO/releases/tag/$RELEASE_TAG"
else
  WHERE="commit $ENGINE_COMMIT (unreleased build)"
  WHERE_URL="https://github.com/$REPO/tree/$ENGINE_COMMIT"
fi

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

log "Source archives"
FF_ARCHIVE="ffmpeg-$FFMPEG_VERSION.tar.gz"
git -C "$SRC_DIR" archive --format=tar.gz --prefix="ffmpeg-$FFMPEG_VERSION/" -o "$DIST/$FF_ARCHIVE" HEAD
{
  echo "Corresponding source for the stashy-videoengine binaries of $WHERE:"
  echo "$WHERE_URL"
  echo "Each archive below is attached there. Build scripts:"
  echo "https://github.com/$REPO/tree/$ENGINE_COMMIT"
  echo
  printf '%s %s\n  %s\n  sha256 %s\n  %s @ %s\n\n' ffmpeg "$FFMPEG_VERSION" "$FF_ARCHIVE" \
    "$(sha256 "$DIST/$FF_ARCHIVE")" https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_COMMIT"
  for lib in $LIBRARIES; do
    [ -f "$ARCHIVES/$lib.source" ] || die "no source record for $lib"
    IFS=$'\t' read -r name version file origin commit < "$ARCHIVES/$lib.source"
    cp "$ARCHIVES/$file" "$DIST/$file"
    printf '%s %s\n  %s\n  sha256 %s\n  %s%s\n\n' "$name" "$version" "$file" \
      "$(sha256 "$DIST/$file")" "$origin" "${commit:+ @ $commit}"
  done
} > "$DIST/SOURCES.txt"
cat "$DIST/SOURCES.txt"

log "Build information"
config_value() {  # config_value <sdk> <macro>: a string macro from FFmpeg's config.h
  sed -n "s/^#define $2 \"\(.*\)\"\$/\1/p" "$BUILD_DIR/scratch/$1/config.h"
}
MIN_IOS="$(xcrun otool -l "$BUILD_DIR/thin/iphoneos/lib/libavutil.a" \
  | awk '$1 == "minos" && !v { v = $2 } END { print v }')"
[ -n "$MIN_IOS" ] || die "no LC_BUILD_VERSION minos in libavutil.a"
LIB_VERSIONS=""
for lib in $LIBRARIES; do
  IFS=$'\t' read -r name version file origin commit < "$ARCHIVES/$lib.source"
  LIB_VERSIONS="$LIB_VERSIONS${LIB_VERSIONS:+, }$name $version"
done
{
  echo "engine: https://github.com/$REPO @ $ENGINE_COMMIT"
  echo "release: ${RELEASE_TAG:-unreleased}"
  echo "ffmpeg: $FFMPEG_VERSION @ $FFMPEG_COMMIT"
  echo "license: $(config_value iphoneos FFMPEG_LICENSE)"
  echo "xcode: $(xcodebuild -version | paste -sd ' ' -)"
  echo "iphoneos_sdk: $(xcrun --sdk iphoneos --show-sdk-version)"
  echo "iphonesimulator_sdk: $(xcrun --sdk iphonesimulator --show-sdk-version)"
  echo "min_ios: $MIN_IOS"
  echo "runner_image: ${ImageOS:-unknown} ${ImageVersion:-}"
  echo "libraries: $LIB_VERSIONS"
  echo "configure_iphoneos: $(config_value iphoneos FFMPEG_CONFIGURATION)"
  echo "configure_iphonesimulator: $(config_value iphonesimulator FFMPEG_CONFIGURATION)"
} > "$DIST/BUILDINFO.txt"
cat "$DIST/BUILDINFO.txt"

log "Licence texts and notice"
rm -rf "$BUILD_DIR/licenses"
mkdir -p "$LIC/ffmpeg" "$LIC/stashy-videoengine"
cp "$SRC_DIR/COPYING.LGPLv2.1" "$SRC_DIR/LICENSE.md" "$LIC/ffmpeg/"
cp "$ROOT/LICENSE" "$LIC/stashy-videoengine/"
cp "$DIST/BUILDINFO.txt" "$LIC/"
LISTING=""
for lib in $LIBRARIES; do
  IFS=$'\t' read -r name version file origin commit < "$ARCHIVES/$lib.source"
  IFS='|' read -r display license files <<< "$(license_of "$lib")"
  mkdir -p "$LIC/$lib" "$BUILD_DIR/licenses/x"
  for member in $files; do
    tar -xf "$ARCHIVES/$file" -C "$BUILD_DIR/licenses/x" "$name-$version/$member"
    cp "$BUILD_DIR/licenses/x/$name-$version/$member" "$LIC/$lib/"
  done
  LISTING="$LISTING$(printf '  %-26s %-20s %s' "$display $version" "$license" "$lib/")
"
done
rm -rf "$BUILD_DIR/licenses/x"
cat > "$LIC/NOTICE.txt" <<EOF
This software uses libraries from the FFmpeg project (https://ffmpeg.org)
under the GNU Lesser General Public License, version 2.1 or later
(ffmpeg/COPYING.LGPLv2.1). FFmpeg $FFMPEG_VERSION is built unmodified with the
configuration in BUILDINFO.txt.

The source code of FFmpeg and of every library below, with the scripts that
build them, is published with stashy-videoengine $WHERE:
$WHERE_URL
A modified FFmpeg can be used by building that repository with the change
and pointing the app's stashy-videoengine package at the result.

This software is based in part on the work of the FreeType Team.

Also included; licence texts are in the folders named:
$LISTING
EOF
cat "$LIC/NOTICE.txt"
rm -f "$DIST/LICENSES.zip"
( cd "$BUILD_DIR/licenses" && ditto -c -k --norsrc --noextattr --keepParent LICENSES "$DIST/LICENSES.zip" )
unzip -l "$DIST/LICENSES.zip"
