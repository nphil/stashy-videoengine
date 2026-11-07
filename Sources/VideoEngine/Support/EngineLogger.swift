/// Where the engine reports what it is doing. Both closures run on engine worker threads.
public struct EngineLogger: Sendable {
    /// A structured event: a short tag such as "remux-header" and its key/value fields.
    public var event: @Sendable (_ tag: String, _ fields: [(String, String)]) -> Void
    /// A free-text line, such as FFmpeg's own log output.
    public var message: @Sendable (String) -> Void

    public init(
        event: @escaping @Sendable (_ tag: String, _ fields: [(String, String)]) -> Void,
        message: @escaping @Sendable (String) -> Void
    ) {
        self.event = event
        self.message = message
    }

    public static let silent = EngineLogger(event: { _, _ in }, message: { _ in })
}
