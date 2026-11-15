import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's build of a workspace, which runs the workspace's own script
/// (apelin-build's `ExternalBuild`): code from the repository, as mobile,
/// as shell_run would run it. Under Confirm each one spends an approval the
/// app gave this session whose own `approvalRequested` names exactly that
/// build (`detail.externalBuild` {projectID, configuration, bootstrap?}), so
/// one approval builds once and nothing is granted for the session (owner,
/// 2026-10-23). The package it makes is installed under the packaging rule
/// every install has (InstallBridge).
enum AgentExternalBuildRules {
    static let detailKey = "externalBuild"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this build.
    static func covers(_ build: BuildStartRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.projectBuild.rawValue, let detail = asked["detail"]?[detailKey] else { return false }
        return detail["projectID"]?.stringValue == build.projectID
            && detail["configuration"]?.stringValue == build.configuration.rawValue
            && detail["bootstrap"]?.stringValue == build.bootstrap?.rawValue
    }

    /// Spends that approval, or the refusal when the session has none.
    static func authorize(_ build: BuildStartRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: { covers(build, asked: $0) }) else {
            return ApelinError(
                .denied,
                "approval required: the user has not approved this build of the workspace \(build.projectID), which runs its own build script",
            )
        }
        return nil
    }
}
