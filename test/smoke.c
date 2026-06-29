// Functional smoke test: links every FFmpeg lib + the VideoToolbox system
// frameworks, then confirms the hardware encoders are registered at runtime.
// Built for the arm64 iOS simulator and run via `xcrun simctl spawn`.
#include <stdio.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>

static int check(const char *name) {
    const AVCodec *c = avcodec_find_encoder_by_name(name);
    printf("  encoder %-20s : %s\n", name, c ? "FOUND" : "MISSING");
    return c != NULL;
}

int main(void) {
    printf("avutil   version : %s\n", av_version_info());
    printf("avcodec  version : %u\n", avcodec_version());

    int ok = 1;
    ok &= check("h264_videotoolbox");
    ok &= check("hevc_videotoolbox");
    ok &= check("aac");

    if (!ok) {
        printf("RESULT: FAIL (a required encoder is missing)\n");
        return 1;
    }
    printf("RESULT: PASS\n");
    return 0;
}
