/// Another conversation of the project, as a message it sent names it.
public struct ConversationSender: Sendable, Hashable {
    public var sessionID: String
    public var title: String?

    public init(sessionID: String, title: String? = nil) {
        self.sessionID = sessionID
        self.title = title
    }

    /// The line the model reads before the message.
    public var prefix: String {
        let name = title.map { "“\($0)” (\(sessionID))" } ?? sessionID
        return "[Message from conversation \(name), another agent working in this project, not from the user]"
    }
}
