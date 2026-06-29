#!/usr/bin/env bash
# ===========================================================================
# build-deps.sh <sdk> <prefix> <srcroot> [min_ios_version]
#
# Cross-compiles the permissive/LGPL external libraries that FFmpeg's
# drawtext / subtitles / zscale filters need, as STATIC libs into <prefix>,
# for one iOS arch=arm64 slice (<sdk> = iphoneos | iphonesimulator):
#
#   fribidi   -> drawtext, libass (bidi)
#   freetype  -> drawtext, libass (font rasterizer)
#   harfbuzz  -> drawtext, libass (text shaping; C++)
#   zimg      -> zscale (HQ scale / colorspace / HDR; C++)
#   libass    -> subtitles / ass (subtitle burn-in)
#   dav1d     -> libdav1d decoder (fast AV1 software decode; meson + arm64 asm)
#
# Each library is skipped if already installed (so a cached <prefix> makes
# this a no-op). FFmpeg later finds them via pkg-config (PKG_CONFIG_LIBDIR).
# Recipes adapted from arthenica/ffmpeg-kit's iOS scripts.
# ===========================================================================
set -euo pipefail

SDK="${1:?usage: build-deps.sh <sdk> <prefix> <srcroot> [min_ios]}"
PREFIX="${2:?missing prefix}"
SRCROOT="${3:?missing srcroot}"
MIN_IOS_VERSION="${4:-16.0}"

FRIBIDI_VERSION=1.0.16
FREETYPE_VERSION=2.13.3
HARFBUZZ_VERSION=11.5.1
ZIMG_VERSION=release-3.0.6
LIBASS_VERSION=0.17.5
DAV1D_VERSION=1.5.1

log() { printf '\n\033[1;35m--> [deps/%s] %s\033[0m\n' "$SDK" "$*"; }

SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"
AR="$(xcrun --sdk "$SDK" -f ar)"
RANLIB="$(xcrun --sdk "$SDK" -f ranlib)"
case "$SDK" in
  iphonesimulator) MINFLAG="-mios-simulator-version-min=$MIN_IOS_VERSION" ;;
  *)               MINFLAG="-mios-version-min=$MIN_IOS_VERSION" ;;
esac
HOST="arm64-apple-darwin"
NJOBS="$(sysctl -n hw.ncpu)"

export CC CXX AR RANLIB SYSROOT HOST PREFIX SRCROOT SDK MINFLAG
export CFLAGS="-arch arm64 -isysroot $SYSROOT $MINFLAG"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$CFLAGS"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

mkdir -p "$SRCROOT" "$PREFIX/lib/pkgconfig"

fetch() {  # fetch <url> <outfile>
  [ -f "$SRCROOT/$2" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$SRCROOT/$2" "$1"
}

# --- fribidi (autotools, pure C) ------------------------------------------
build_fribidi() {
  [ -f "$PREFIX/lib/pkgconfig/fribidi.pc" ] && { log "fribidi cached"; return; }
  log "fribidi $FRIBIDI_VERSION"
  fetch "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz" "fribidi.tar.xz"
  rm -rf "$SRCROOT/fribidi-$FRIBIDI_VERSION"
  tar xf "$SRCROOT/fribidi.tar.xz" -C "$SRCROOT"
  cd "$SRCROOT/fribidi-$FRIBIDI_VERSION"
  ./configure --prefix="$PREFIX" --host="$HOST" --enable-static --disable-shared \
    --with-pic --disable-fast-install --disable-debug --disable-deprecated \
    CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
  # doc/ needs c2man (absent on the runner); drop it from SUBDIRS.
  sed -i.bak 's/ doc / /' Makefile
  make -j"$NJOBS"
  make install
}

# --- freetype (autotools, C; no optional deps) ----------------------------
build_freetype() {
  [ -f "$PREFIX/lib/pkgconfig/freetype2.pc" ] && { log "freetype cached"; return; }
  log "freetype $FREETYPE_VERSION"
  fetch "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz" "freetype.tar.xz"
  rm -rf "$SRCROOT/freetype-$FREETYPE_VERSION"
  tar xf "$SRCROOT/freetype.tar.xz" -C "$SRCROOT"
  cd "$SRCROOT/freetype-$FREETYPE_VERSION"
  ./configure --prefix="$PREFIX" --host="$HOST" --with-pic --enable-static --disable-shared \
    --disable-fast-install --without-harfbuzz --without-png --without-brotli \
    --without-bzip2 --without-zlib \
    CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"
  make -j"$NJOBS"
  make install
}

# --- harfbuzz (meson, C++; needs freetype) --------------------------------
build_harfbuzz() {
  [ -f "$PREFIX/lib/pkgconfig/harfbuzz.pc" ] && { log "harfbuzz cached"; return; }
  log "harfbuzz $HARFBUZZ_VERSION"
  fetch "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz" "harfbuzz.tar.xz"
  rm -rf "$SRCROOT/harfbuzz-$HARFBUZZ_VERSION"
  tar xf "$SRCROOT/harfbuzz.tar.xz" -C "$SRCROOT"
  cd "$SRCROOT/harfbuzz-$HARFBUZZ_VERSION"
  rm -rf _build

  # meson array literal from a space-separated flag string
  meson_arr() { printf "'%s', " $1 | sed 's/, $//'; }
  cat > ios-cross.txt <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
ranlib = '$RANLIB'
strip = 'strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = [$(meson_arr "$CFLAGS")]
cpp_args = [$(meson_arr "$CXXFLAGS")]
c_link_args = [$(meson_arr "$LDFLAGS")]
cpp_link_args = [$(meson_arr "$LDFLAGS")]
EOF

  meson setup _build --cross-file ios-cross.txt --prefix "$PREFIX" --libdir lib \
    --buildtype release --default-library static \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
    -Dicu=disabled -Dgraphite2=disabled -Dchafa=disabled -Dcoretext=disabled \
    -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
  meson compile -C _build
  meson install -C _build
}

# --- zimg (autotools via autogen.sh, C++; git submodules) -----------------
build_zimg() {
  [ -f "$PREFIX/lib/pkgconfig/zimg.pc" ] && { log "zimg cached"; return; }
  log "zimg $ZIMG_VERSION"
  rm -rf "$SRCROOT/zimg"
  git clone --depth 1 --branch "$ZIMG_VERSION" --recurse-submodules \
    https://github.com/sekrit-twc/zimg.git "$SRCROOT/zimg"
  cd "$SRCROOT/zimg"
  ./autogen.sh
  ./configure --host="$HOST" --prefix="$PREFIX" --enable-static --disable-shared \
    --with-pic --disable-testapp --disable-example --disable-unit-test \
    CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"
  make -j"$NJOBS"
  make install
}

# --- libass (autotools, C; needs freetype + fribidi + harfbuzz) -----------
build_libass() {
  [ -f "$PREFIX/lib/pkgconfig/libass.pc" ] && { log "libass cached"; return; }
  log "libass $LIBASS_VERSION"
  fetch "https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.gz" "libass.tar.gz"
  rm -rf "$SRCROOT/libass-$LIBASS_VERSION"
  tar xzf "$SRCROOT/libass.tar.gz" -C "$SRCROOT"
  cd "$SRCROOT/libass-$LIBASS_VERSION"
  ./configure --prefix="$PREFIX" --host="$HOST" --with-pic --enable-static --disable-shared \
    --disable-fast-install --disable-asm --disable-fontconfig --disable-coretext \
    --disable-directwrite --disable-libunibreak --disable-require-system-font-provider \
    --disable-test --disable-profile --disable-fuzz \
    CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"
  make -j"$NJOBS"
  make install
}

# --- dav1d (meson, C + arm64 NEON asm; fast AV1 decoder; no external deps) -
# Reuses the same meson cross-file shape as harfbuzz. arm64 asm assembles with
# the clang integrated assembler (nasm is only needed for x86), so no extra
# assembler is required for the iOS slices. Installs libdav1d.a + dav1d.pc;
# FFmpeg picks it up via pkg-config and --enable-libdav1d. build-ffmpeg.sh then
# merges libdav1d.a INTO libavcodec.a (the lib that references it) so the
# shipped xcframework stays self-contained.
build_dav1d() {
  [ -f "$PREFIX/lib/pkgconfig/dav1d.pc" ] && { log "dav1d cached"; return; }
  log "dav1d $DAV1D_VERSION"
  rm -rf "$SRCROOT/dav1d-$DAV1D_VERSION"
  git clone --depth 1 --branch "$DAV1D_VERSION" \
    https://github.com/videolan/dav1d.git "$SRCROOT/dav1d-$DAV1D_VERSION"
  cd "$SRCROOT/dav1d-$DAV1D_VERSION"
  rm -rf _build

  meson_arr() { printf "'%s', " $1 | sed 's/, $//'; }
  cat > ios-cross.txt <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
ranlib = '$RANLIB'
strip = 'strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = [$(meson_arr "$CFLAGS")]
c_link_args = [$(meson_arr "$LDFLAGS")]
EOF

  meson setup _build --cross-file ios-cross.txt --prefix "$PREFIX" --libdir lib \
    --buildtype release --default-library static \
    -Denable_tools=false -Denable_tests=false
  meson compile -C _build
  meson install -C _build
}

log "Building external libraries into $PREFIX"
build_fribidi
build_freetype
build_harfbuzz
build_zimg
build_libass
build_dav1d
log "External libraries ready"
