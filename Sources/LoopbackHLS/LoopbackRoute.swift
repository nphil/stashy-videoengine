import Foundation

/// One path the loopback server answers, matched exactly (the query string is ignored).
public struct LoopbackRoute: Sendable {
    public enum Content: Sendable {
        /// A playlist that may not exist yet. Requests wait for a non-nil value, then get 503.
        case playlist(@Sendable () -> String?)
        /// Range reads of a file that is still being written. `availableBytes` is the producer's
        /// verified write position; once `isComplete` is true a range past it is a real end of file.
        case growingFile(URL, availableBytes: @Sendable () -> Int64, isComplete: @Sendable () -> Bool,
                         contentType: String)
        /// A fixed body.
        case data(Data, contentType: String)
    }

    public let path: String
    public let content: Content

    public init(path: String, _ content: Content) {
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.content = content
    }
}
