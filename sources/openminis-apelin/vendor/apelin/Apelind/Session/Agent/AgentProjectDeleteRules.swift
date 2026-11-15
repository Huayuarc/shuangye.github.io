import ApelinCore
import ApelinProtocol
import Foundation

/// A project deleted for good (`projectDelete`; apelin_project_delete,
/// owner, 2026-10-29): its folder under `Projects/` with every file in it,
/// and the conversations of it, which the host closes first. The project
/// is the one whose `apelin-project.json` carries the id asked for, in a
/// real folder directly under `Projects/` (`AgentProjects.resolve`: a link
/// out, or a folder holding another id, is refused), never a temporary
/// chat's. An agent never deletes its own session's project, the
/// workspace it runs in, and under Confirm deletes another only by
/// spending an approval the app gave that session whose own
/// `approvalRequested` names exactly that project (`detail.projectDelete`
/// {projectID, folder, displayName}), once, never for the session; Relaxed
/// and Full delete it as the app's Delete does.
enum AgentProjectDeleteRules {
    static let detailKey = "projectDelete"

    /// The project `delete` names, as the host resolves every project:
    /// by its id, in the folder named when one is.
    static func target(_ delete: ProjectDeleteRequest, home: String) throws -> ResolvedProject {
        guard !delete.projectID.hasPrefix(ResolvedProject.temporaryIDPrefix) else {
            throw ApelinError(.badRequest, "A temporary chat's folder is no project: it goes with its chat.")
        }
        return try AgentProjects.resolve(home: home, projectID: delete.projectID, projectName: delete.projectName)
    }

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves deleting exactly `target`.
    static func covers(_ target: ResolvedProject, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.projectDelete.rawValue,
              let detail = asked["detail"]?[detailKey]
        else { return false }
        return detail["projectID"]?.stringValue == target.id && detail["folder"]?.stringValue == target.name
    }

    /// Nil when the session may delete `target`, else why not; under
    /// Confirm the approval that covers it is spent.
    static func authorize(_ target: ResolvedProject, session: String?, registry: TaskRegistry) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard target.id != entry.project.id else {
            return ApelinError(
                .denied,
                "a conversation cannot delete its own project, which it runs in: delete it from General Chat or another project's conversation, or in Projects ▸ All Projects…",
            )
        }
        guard entry.mode.asks else { return nil }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: { covers(target, asked: $0) }) else {
            return ApelinError(.denied, "approval required: the user has not approved deleting the project \(target.name)")
        }
        return nil
    }
}
