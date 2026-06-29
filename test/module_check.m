// Compile-only check (clang -fmodules -fsyntax-only) that every generated
// module map parses and that cross-module includes (e.g. libavcodec headers
// pulling in <libavutil/...>) resolve as modules. No linking, no runtime.
@import Libavutil;
@import Libavcodec;
@import Libavformat;
@import Libavfilter;
@import Libswscale;
@import Libswresample;

int main(void) {
    return 0;
}
