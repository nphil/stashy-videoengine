import Foundation
import LoopbackHLS
import Testing

struct SubtitleTrackTests {
    @Test func writesShiftedEscapedWebVTT() {
        let cue = SubtitleCue(start: 3662.5, end: 3664, text: WebVTT.escape("Tom & <Jerry>"))
        #expect(WebVTT.document([cue], origin: 1) == """
            WEBVTT
            X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0

            01:01:01.500 --> 01:01:03.000
            Tom &amp; &lt;Jerry&gt;

            """)
    }

    @Test func listsASlotOnlyOnceTheProducerHasReadPastIt() throws {
        let track = SubtitleTrack(targetDuration: 6)
        #expect(track.targetDuration == 10)
        track.add(SubtitleCue(start: 9, end: 13, text: "Spans two slots"))
        track.setOrigin(1)
        track.readThrough(14)
        #expect(!track.playlist(slotPrefix: "").contains(".vtt"))
        #expect(track.slot(0) == nil)

        track.readThrough(15)
        #expect(track.playlist(slotPrefix: "").contains("\n0.vtt\n"))
        #expect(try #require(track.slot(0)).contains("00:00:08.000 --> 00:00:12.000\nSpans two slots"))
        #expect(track.slot(1) == nil)

        track.finish(duration: 12.5)
        #expect(track.playlist(slotPrefix: "").hasSuffix("#EXTINF:2.500,\n1.vtt\n#EXT-X-ENDLIST\n"))
        // A cue repeats in every slot it overlaps.
        #expect(try #require(track.slot(1)).contains("Spans two slots"))
    }

    @Test func multivariantPlaylistOffersSubtitleRenditions() {
        let variant = HLSVariant(uri: "index.m3u8", bandwidth: 1_000_000)
        let rendition = HLSSubtitleRendition(name: "English", language: "en", uri: "subs/0/index.m3u8", forced: true)
        let text = HLSMultivariantPlaylist(variants: [variant], subtitles: [rendition]).render()
        #expect(text.contains("""
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,\
            FORCED=YES,URI="subs/0/index.m3u8"
            """))
        #expect(text.contains("SUBTITLES=\"subs\"\nindex.m3u8\n"))
    }
}
