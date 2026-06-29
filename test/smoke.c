// Functional smoke test: links every FFmpeg lib + the system frameworks, then
// confirms the encoders, decoders, filters and muxers we promise are actually
// registered at runtime. Built for the arm64 iOS simulator, run via
// `xcrun simctl spawn`. Returns non-zero if any required component is missing.
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavutil/avutil.h>

static int fails = 0;

static void need_encoder(const char *n) {
    int ok = avcodec_find_encoder_by_name(n) != NULL;
    printf("  encoder %-22s : %s\n", n, ok ? "FOUND" : "MISSING");
    if (!ok) fails++;
}
static void need_decoder(const char *n) {
    int ok = avcodec_find_decoder_by_name(n) != NULL;
    printf("  decoder %-22s : %s\n", n, ok ? "FOUND" : "MISSING");
    if (!ok) fails++;
}
static void need_filter(const char *n) {
    int ok = avfilter_get_by_name(n) != NULL;
    printf("  filter  %-22s : %s\n", n, ok ? "FOUND" : "MISSING");
    if (!ok) fails++;
}
static void need_muxer(const char *n) {
    int ok = av_guess_format(n, NULL, NULL) != NULL;
    printf("  muxer   %-22s : %s\n", n, ok ? "FOUND" : "MISSING");
    if (!ok) fails++;
}

int main(void) {
    printf("avutil version : %s\n", av_version_info());

    // Hardware + audio encoders (contract from v1.0.0).
    need_encoder("h264_videotoolbox");
    need_encoder("hevc_videotoolbox");
    need_encoder("aac");
    need_encoder("mov_text");          // soft-subtitle mux into MP4

    // AVPlayer-incompatible audio we must transcode to AAC.
    need_decoder("dca");               // DTS
    need_decoder("truehd");
    need_decoder("hdmv_pgs_subtitle"); // PGS subs

    // Built-in + VideoToolbox hardware filters.
    need_filter("scale");
    need_filter("scale_vt");
    need_filter("tonemap_vt");
    need_filter("unsharp");
    need_filter("hqdn3d");
    need_filter("yadif");
    need_filter("overlay");

    // Muxers (HLS bridge to AVPlayer).
    need_muxer("hls");

    if (fails) {
        printf("RESULT: FAIL (%d required component(s) missing)\n", fails);
        return 1;
    }
    printf("RESULT: PASS\n");
    return 0;
}
