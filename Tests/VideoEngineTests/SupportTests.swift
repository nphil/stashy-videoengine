import Foundation
import Testing
@testable import VideoEngine

struct FFConstantsTests {
    /// The hand-written error codes must keep matching the linked FFmpeg; a drift after an upgrade fails here.
    @Test func errorCodesMatchFFmpeg() {
        #expect(FF.errorString(FF.averrorEOF) == "End of file")
        #expect(FF.errorString(FF.averrorExit) == "Immediate exit requested")
        #expect(FF.errorString(FF.eio) == "Input/output error")
        #expect(FF.errorString(FF.enospc) == "No space left on device")
        #expect(FF.errorString(FF.eagain) == "Resource temporarily unavailable")
        #expect(FF.errorString(FF.enosys) == "Function not implemented")
    }

    @Test func fourCCRoundTrips() {
        #expect(FF.fourCC(FF.tag("hvc1")) == "hvc1")
        #expect(FF.fourCC(0) == nil)
    }
}
