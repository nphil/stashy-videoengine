// Functional smoke test: links every FFmpeg lib + the system frameworks, then
// confirms a representative slice of the comprehensive LGPL component set is
// actually registered at runtime. Built for the arm64 iOS simulator, run via
// `xcrun simctl spawn`. Returns non-zero if any required component is missing.
//
// Only LGPL components are asserted. Notable omissions are intentional:
// hqdn3d/eq/cropdetect are GPL; tonemap_vt does not exist in FFmpeg (software
// tonemap + zscale cover HDR->SDR). Registration is all this proves: the
// simulator has no VideoToolbox hardware, so hwaccels are checked as
// registered, not as working.
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>

// verify.sh passes FFmpegSupport.ffmpegVersion, so the Swift constant cannot
// drift from the binaries.
#ifndef EXPECTED_FFMPEG_VERSION
#error "build with -DEXPECTED_FFMPEG_VERSION=\"nX.Y.Z\""
#endif

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
static void need_demuxer(const char *n) {
    int ok = av_find_input_format(n) != NULL;
    printf("  demuxer %-22s : %s\n", n, ok ? "FOUND" : "MISSING");
    if (!ok) fails++;
}
static void need_bsf(const char *n) {
    int ok = av_bsf_get_by_name(n) != NULL;
    printf("  bsf     %-22s : %s\n", n, ok ? "FOUND" : "MISSING");
    if (!ok) fails++;
}
static void need_protocol(const char *n) {
    void *opaque = NULL;
    const char *p;
    int ok = 0;
    while ((p = avio_enum_protocols(&opaque, 0)))
        if (!strcmp(p, n)) ok = 1;
    printf("  proto   %-22s : %s\n", n, ok ? "FOUND" : "MISSING");
    if (!ok) fails++;
}
// Registration only: a VideoToolbox hw_config on the decoder.
static void need_vt_hwaccel(const char *n) {
    const AVCodec *c = avcodec_find_decoder_by_name(n);
    const AVCodecHWConfig *cfg;
    int ok = 0;
    for (int i = 0; c && (cfg = avcodec_get_hw_config(c, i)); i++)
        if (cfg->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) ok = 1;
    printf("  hwaccel %-22s : %s\n", n, ok ? "VIDEOTOOLBOX" : "MISSING");
    if (!ok) fails++;
}

int main(void) {
    printf("FFmpeg version : %s\n", av_version_info());
    printf("configuration  : %s\n", avcodec_configuration());
    if (strcmp(av_version_info(), EXPECTED_FFMPEG_VERSION)) {
        printf("  version mismatch: FFmpegSupport.ffmpegVersion is %s\n", EXPECTED_FFMPEG_VERSION);
        fails++;
    }
    // Every component must stay LGPL: a GPL or nonfree flag changes this.
    printf("license        : %s\n", avutil_license());
    if (strncmp(avutil_license(), "LGPL", 4)) fails++;

    // Demuxers the engine opens.
    need_demuxer("matroska");
    need_demuxer("mov");
    need_demuxer("mpegts");

    // Encoders: hardware video (incl. new ProRes) + audio + soft-subtitle mux.
    need_encoder("h264_videotoolbox");
    need_encoder("hevc_videotoolbox");
    need_encoder("prores_videotoolbox");  // new VideoToolbox encoder in 8.x
    need_encoder("aac");
    need_encoder("aac_at");     // AudioToolbox AAC
    need_encoder("ac3");
    need_encoder("eac3");
    need_encoder("mov_text");
    need_encoder("webvtt");

    // Decoders: AVPlayer-incompatible audio + subtitle formats.
    need_decoder("dca");        // DTS
    need_decoder("truehd");
    need_decoder("mlp");
    need_decoder("alac");
    need_decoder("opus");
    need_decoder("flac");
    need_decoder("vorbis");
    need_decoder("ac3");
    need_decoder("eac3");
    need_decoder("aac_at");     // AudioToolbox decoders
    need_decoder("ac3_at");
    need_decoder("eac3_at");
    need_decoder("libdav1d");   // fast AV1 software decode (vs built-in av1)
    need_decoder("pgssub");     // HDMV PGS bitmap subtitles
    need_decoder("dvdsub");     // DVD bitmap subtitles
    need_decoder("dvbsub");     // DVB bitmap subtitles
    need_decoder("subrip");
    need_decoder("webvtt");
    need_decoder("ass");

    // Hardware decode registration.
    need_vt_hwaccel("h264");
    need_vt_hwaccel("hevc");
    need_vt_hwaccel("av1");
    need_vt_hwaccel("vp9");

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

    // Bitstream filters: lossless audio cores, Dolby Vision RPU, PGS.
    need_bsf("dca_core");
    need_bsf("truehd_core");
    need_bsf("eac3_core");
    need_bsf("dovi_rpu");
    need_bsf("filter_units");
    need_bsf("pgs_frame_merge");

    // https/tls fail quietly when the SecureTransport probe fails.
    need_protocol("file");
    need_protocol("https");
    need_protocol("tls");

    if (fails) {
        printf("RESULT: FAIL (%d required component(s) missing)\n", fails);
        return 1;
    }
    printf("RESULT: PASS\n");
    return 0;
}
