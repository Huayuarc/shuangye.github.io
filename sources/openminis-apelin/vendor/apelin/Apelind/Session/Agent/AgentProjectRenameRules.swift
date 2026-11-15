import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's `projectRename` (apelin_project_rename, owner, 2026-10-24):
/// its own session's project's displayName in every mode — a label the
/// file tools may write there anyway and no approval digest counts —, and
/// another project's under Confirm only by spending an approval the app
/// gave that session for exactly that project and name
/// (`detail.projectRename`), once, never for the session; Relaxed and Full
/// rename it without one, as the agent's gate lets them. A temporary chat
/// has no project to rename, and an automatic rename (`onlyIfAutomatic`)
/// is the session's own project's alone.
enum AgentProjectRenameRules {
    static let detailKey = "projectRename"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this rename.
    static func covers(_ rename: ProjectRenameRequest, target: ResolvedProject, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.projectRename.rawValue,
              let detail = asked["detail"]?[detailKey]
        else { return false }
        return detail["projectID"]?.stringValue == target.id && detail["displayName"]?.stringValue == rename.displayName
    }

    /// Nil when the session may rename the project as asked, else why not.
    /// The project is resolved by id alone, so the build worker renames the
    /// project decided on here, never a folder that happens to be named so.
    static func authorize(_ rename: ProjectRenameRequest, session: String?, home: String, registry: TaskRegistry) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        let target: ResolvedProject
        do {
            target = try AgentProjects.resolve(home: home, projectID: rename.projectID, projectName: nil)
        } catch {
            return error as? ApelinError ?? ApelinError(.notFound, "no project has the id \(rename.projectID)")
        }
        if target.id == entry.project.id {
            return nil
        }
        if rename.onlyIfAutomatic {
            return ApelinError(.badRequest, "an automatic rename is for the session's own project")
        }
        guard entry.mode.asks else { return nil }
        let approved = await AgentApprovals.spend(entry: entry, registry: registry) { covers(rename, target: target, asked: $0) }
        guard approved else {
            return ApelinError(
                .denied,
                "approval required: the user has not approved renaming the project \(target.name) to “\(rename.displayName)”",
            )
        }
        return nil
    }
}
