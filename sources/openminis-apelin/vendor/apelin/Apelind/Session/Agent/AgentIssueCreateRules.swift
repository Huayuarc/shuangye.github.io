import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's `gitIssueCreate` (apelin_git_create_issue, owner,
/// 2026-10-30): an issue under the user's GitHub account on a repository
/// the user chose, which anyone who can see that repository reads; so, like
/// feedback, it asks under Confirm every time. Each one spends an approval
/// the app gave this session whose own `approvalRequested` names exactly
/// that repository and issue (`detail.issueCreate` {repository, title,
/// body}), once, never for the session; Relaxed and Full open it without
/// asking. apelin-environment checks the text again (`FeedbackRules`) and
/// writes the footer itself.
enum AgentIssueCreateRules {
    static let detailKey = "issueCreate"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this issue.
    static func covers(_ issue: GitIssueCreateRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.gitCreateIssue.rawValue,
              let detail = asked["detail"]?[detailKey]
        else { return false }
        return detail["repository"]?.stringValue == issue.repository
            && detail["title"]?.stringValue == issue.title
            && detail["body"]?.stringValue == issue.body
    }

    /// Nil when the session may open it, else why not; under Confirm the
    /// approval that covers it is spent.
    static func authorize(_ issue: GitIssueCreateRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard entry.mode.asks else { return nil }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: { covers(issue, asked: $0) }) else {
            return ApelinError(
                .denied,
                "approval required: the user has not approved opening this issue on \(issue.repository)",
            )
        }
        return nil
    }
}
