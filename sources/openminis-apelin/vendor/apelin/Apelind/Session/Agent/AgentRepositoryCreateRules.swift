import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's `gitRepositoryCreate` (apelin_git_create_repository, owner,
/// 2026-10-29): a repository on GitHub under the user's account, public or
/// private, which outlives the conversation; so, like a push, it asks under
/// Confirm every time. Each one spends an approval the app gave this session
/// whose own `approvalRequested` names exactly that repository
/// (`detail.repositoryCreate` {owner?, name, visibility, description?}),
/// once, never for the session; Relaxed and Full make it as they push.
/// apelin-environment checks the request again (`problem`).
enum AgentRepositoryCreateRules {
    static let detailKey = "repositoryCreate"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this repository.
    static func covers(_ create: GitRepositoryCreateRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.gitCreateRepository.rawValue,
              let detail = asked["detail"]?[detailKey]
        else { return false }
        return detail["owner"]?.stringValue == create.owner
            && detail["name"]?.stringValue == create.name
            && detail["visibility"]?.stringValue == create.visibility.rawValue
            && detail["description"]?.stringValue == create.description
    }

    /// Nil when the session may make it, else why not; under Confirm the
    /// approval that covers it is spent.
    static func authorize(_ create: GitRepositoryCreateRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard entry.mode.asks else { return nil }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: { covers(create, asked: $0) }) else {
            let owner = create.owner.map { "\($0)/" } ?? ""
            return ApelinError(
                .denied,
                "approval required: the user has not approved creating the \(create.visibility.rawValue) repository \(owner)\(create.name) on GitHub",
            )
        }
        return nil
    }
}
