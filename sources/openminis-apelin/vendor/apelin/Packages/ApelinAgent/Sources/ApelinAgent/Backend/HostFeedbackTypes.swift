import Foundation

// MARK: - feedback

/// An issue apelin_feedback_send files on Apelin's own repository: the title
/// and body its card showed, nothing else. The repository is the host's
/// constant, and the footer apelin-environment's.
public struct FeedbackToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var title: String
    public var body: String
    public init(context: HostCallContext, title: String, body: String) {
        self.context = context
        self.title = title
        self.body = body
    }
}

public struct FeedbackToolResponse: Sendable, Hashable, Codable {
    public var repository: String
    /// The issue's number there.
    public var issue: Int
    /// Its page on GitHub, which the user is given.
    public var url: String
    public init(repository: String, issue: Int, url: String) {
        self.repository = repository
        self.issue = issue
        self.url = url
    }
}

/// The issue apelin_feedback_read reads, and apelin_feedback_edit reads
/// again before it asks.
public struct FeedbackReadToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var number: Int
    public init(context: HostCallContext, number: Int) {
        self.context = context
        self.number = number
    }
}

public struct FeedbackReadToolResponse: Sendable, Hashable, Codable {
    public var repository: String
    /// The issue's number there.
    public var issue: Int
    public var url: String
    public var title: String
    /// `open` or `closed`.
    public var state: String
    /// The login of the account that opened it.
    public var author: String
    /// Whether the user's GitHub account opened it: only then can it be
    /// edited.
    public var openedByUser: Bool
    /// The body without the line Apelin added below it.
    public var body: String
    /// That line, nil when the body does not end with one.
    public var footer: String?
    /// The title and body this read saw, named: an edit made against them
    /// passes it back.
    public var revision: String

    public init(
        repository: String,
        issue: Int,
        url: String,
        title: String,
        state: String,
        author: String,
        openedByUser: Bool,
        body: String,
        footer: String?,
    ) {
        self.repository = repository
        self.issue = issue
        self.url = url
        self.title = title
        self.state = state
        self.author = author
        self.openedByUser = openedByUser
        self.body = body
        self.footer = footer
        revision = FeedbackEdit.revision(title: title, body: body)
    }
}

/// An edit apelin_feedback_edit makes: the fields its card showed (nil for
/// one that stays) and the title and body it was made against, which
/// apelin-environment requires the issue still to have.
public struct FeedbackEditToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var number: Int
    public var title: String?
    public var body: String?
    public var expectedTitle: String
    public var expectedBody: String
    public init(
        context: HostCallContext,
        number: Int,
        title: String?,
        body: String?,
        expectedTitle: String,
        expectedBody: String,
    ) {
        self.context = context
        self.number = number
        self.title = title
        self.body = body
        self.expectedTitle = expectedTitle
        self.expectedBody = expectedBody
    }
}

public struct FeedbackEditToolResponse: Sendable, Hashable, Codable {
    public var repository: String
    public var issue: Int
    /// Its page on GitHub, which the user is given.
    public var url: String
    /// `title`, `body` or both: what the edit changed.
    public var changed: [String]
    /// The revision of the title and body the issue has now, which a
    /// further edit made against them passes.
    public var revision: String
    public init(repository: String, issue: Int, url: String, changed: [String], title: String, body: String) {
        self.repository = repository
        self.issue = issue
        self.url = url
        self.changed = changed
        revision = FeedbackEdit.revision(title: title, body: body)
    }
}

/// A refusal in words the model can act on and pass on to the user.
public struct FeedbackToolFailure: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}
