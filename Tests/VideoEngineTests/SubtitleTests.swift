import Foundation
import Testing
@testable import VideoEngine

struct SubtitleTests {
    private func convert(_ text: String) -> String {
        SubtitleDecoder.webVTTText(fromASS: "0,0,Default,,0,0,0,," + text)
    }

    @Test func convertsASSEventsToWebVTTCueText() {
        #expect(convert("{\\i1}Hi{\\i0}\\Nthere & <you>") == "<i>Hi</i>\nthere &amp; &lt;you&gt;")
        // WebVTT tags nest, so closing an outer one reopens the inner.
        #expect(convert("{\\b1}a{\\i1}b{\\b0}c") == "<b>a<i>b</i></b><i>c</i>")
        // Positioning is dropped, and drawings with it.
        #expect(convert("{\\pos(10,20)}Sign{\\p1}m 0 0 l 1 1{\\p0}") == "Sign")
    }

    @Test func namesLanguagesTheWayHLSExpects() {
        #expect(SubtitleLanguage.tag("eng") == "en")
        #expect(SubtitleLanguage.tag(nil) == "und")
        #expect(SubtitleLanguage.displayName("en") == "English")
    }
}
