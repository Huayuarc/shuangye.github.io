import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's `feedbackSend` (apelin_feedback_send, owner, 2026-10-29): a
/// public issue on `FeedbackRules.repository` under the user's GitHub
/// account, so, like a push, it asks under Confirm every time. Each one
/// spends an approval the app gave this session whose own
/// `approvalRequested` names exactly that issue (`detail.feedback`
/// {repository, title, body}), once, never for the session; Relaxed and
/// Full send it as they push. apelin-environment checks the text again
/// (`FeedbackRules`) and writes the footer itself.
///
/// Its `feedbackEdit` (apelin_feedback_edit, owner, 2026-10-30) of an issue
/// the account opened there is held the same way: under Confirm it spends
/// the approval naming exactly that issue, the title and body it puts in
/// (absent for one that stays) and the ones it was made against
/// (`detail.feedbackEdit` {repository, number, url, title?, body?,
/// currentTitle, currentBody}). apelin-environment edits only while the
/// issue still says those, and only an issue the account opened.
enum AgentFeedbackRules {
    static let detailKey = "feedback"
    static let editDetailKey = "feedbackEdit"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this issue.
    static func covers(_ feedback: FeedbackSendRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.feedbackSend.rawValue, let detail = asked["detail"]?[detailKey] else {
            return false
        }
        return detail["repository"]?.stringValue == FeedbackRules.repository
            && detail["title"]?.stringValue == feedback.title
            && detail["body"]?.stringValue == feedback.body
    }

    /// Whether `asked` approves exactly this edit: the issue, what it puts
    /// in, and what it was made against.
    static func covers(_ edit: FeedbackEditRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.feedbackEdit.rawValue,
              let detail = asked["detail"]?[editDetailKey],
              detail["repository"]?.stringValue == FeedbackRules.repository,
              detail["number"]?.doubleValue == Double(edit.number)
        else { return false }
        return field(detail["title"], is: edit.title) && field(detail["body"], is: edit.body)
            && detail["currentTitle"]?.stringValue == edit.expectedTitle
            && detail["currentBody"]?.stringValue == edit.expectedBody
    }

    /// A field the card leaves out stays; one it names is that text.
    private static func field(_ value: JSONValue?, is sent: String?) -> Bool {
        switch (value, sent) {
        case (nil, nil): true
        case let (.string(shown)?, given?): shown == given
        default: false
        }
    }

    /// Nil when the session may send it, else why not; under Confirm the
    /// approval that covers it is spent.
    static func authorize(_ feedback: FeedbackSendRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        await authorize(
            session: session,
            registry: registry,
            covers: { covers(feedback, asked: $0) },
            refusal: "approval required: the user has not approved posting this issue on \(FeedbackRules.repository)",
        )
    }

    /// Nil when the session may make this edit, else why not; under Confirm
    /// the approval that covers it is spent.
    static func authorize(_ edit: FeedbackEditRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        await authorize(
            session: session,
            registry: registry,
            covers: { covers(edit, asked: $0) },
            refusal: "approval required: the user has not approved this edit of issue #\(edit.number) on \(FeedbackRules.repository)",
        )
    }

    private static func authorize(
        session: String?,
        registry: TaskRegistry,
        covers: (JSONValue) -> Bool,
        refusal: String,
    ) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard entry.mode.asks else { return nil }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: covers) else {
            return ApelinError(.denied, refusal)
        }
        return nil
    }
}
