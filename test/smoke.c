// Functional smoke test: links every FFmpeg lib + the system frameworks, then
// confirms a representative slice of the comprehensive LGPL component set is
// actually registered at runtime. Built for the arm64 iOS simulator, run via
// `xcrun simctl spawn`. Returns non-zero if any required component is missing.
//
// FFmpeg 8.1.2, min iOS 16. Only LGPL components are asserted. Notable
// omissions are intentional: hqdn3d/eq/cropdetect are GPL; tonemap_vt does not
// exist in FFmpeg (software tonemap + zscale cover HDR->SDR). At min iOS 16 the
// VideoToolbox scale_vt/transpose_vt filters ARE available and asserted below.
#include <stdio.h>
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

    // Encoders: hardware video (incl. new ProRes) + audio + soft-subtitle mux.
    need_encoder("h264_videotoolbox");
    need_encoder("hevc_videotoolbox");
    need_encoder("prores_videotoolbox");  // new VideoToolbox encoder in 8.x
    need_encoder("aac");
    need_encoder("mov_text");

    // Decoders: AVPlayer-incompatible audio + subtitle formats.
    need_decoder("dca");        // DTS
    need_decoder("truehd");
    need_decoder("mlp");
    need_decoder("alac");
    need_decoder("libdav1d");   // fast AV1 software decode (vs built-in av1)
    need_decoder("pgssub");     // HDMV PGS bitmap subtitles
    need_decoder("dvdsub");     // DVD bitmap subtitles
    need_decoder("dvbsub");     // DVB bitmap subtitles
    need_decoder("subrip");
    need_decoder("webvtt");
    need_decoder("ass");

    // Filters: built-in (LGPL) + VideoToolbox hardware + external-library.
    need_filter("scale");
    need_filter("format");
    need_filter("colorspace");
    need_filter("curves");
    need_filter("lut3d");
    need_filter("unsharp");
    need_filter("cas");
    need_filter("atadenoise");
    need_filter("nlmeans");
    need_filter("deband");
    need_filter("tonemap");
    need_filter("yadif");
    need_filter("bwdif");
    need_filter("transpose");
    need_filter("crop");
    need_filter("pad");
    need_filter("fps");
    need_filter("overlay");
    need_filter("hstack");
    need_filter("vstack");
    need_filter("setpts");
    need_filter("yadif_videotoolbox");  // VideoToolbox hardware deinterlace (Metal)
    need_filter("scale_vt");            // VideoToolbox HW scale (iOS 16)
    need_filter("transpose_vt");        // VideoToolbox HW rotate (iOS 16)
    need_filter("zscale");              // libzimg
    need_filter("drawtext");            // libfreetype + harfbuzz + fribidi
    need_filter("subtitles");           // libass
    // Audio leveling + pitch-corrected speed.
    need_filter("loudnorm");            // EBU R128 loudness normalization
    need_filter("dynaudnorm");
    need_filter("atempo");
    need_filter("aresample");

    // Muxers: MP4/MOV + MPEG-TS + HLS bridge to AVPlayer.
    need_muxer("mov");
    need_muxer("mp4");
    need_muxer("mpegts");
    need_muxer("hls");
    need_muxer("segment");

    if (fails) {
        printf("RESULT: FAIL (%d required component(s) missing)\n", fails);
        return 1;
    }
    printf("RESULT: PASS\n");
    return 0;
}
