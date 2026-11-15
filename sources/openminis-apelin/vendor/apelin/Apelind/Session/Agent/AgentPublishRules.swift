import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's `distributionPublish` (apelin_package_publish; owner,
/// 2026-10-29): packages builds made, put in the user's package repository
/// where anyone who adds the source can install them, so, like a push, it
/// asks under Confirm every time. In every mode the request names the
/// repository and each package's digest, and each file is a package a
/// build reported to this host (ArtifactRegistry) with that digest, so the
/// agent publishes only what Apelin built, as it was built, never a `.deb`
/// it made itself.
/// Under Confirm each one spends an approval the app gave this session
/// whose own `approvalRequested` names exactly that repository and those
/// files and digests, in order (`detail.packagePublish` {repository,
/// sourceURL?, packages: [{buildID, packageID, version, architecture,
/// bootstrap, file, digest}]}), once, never for the session; Relaxed and
/// Full publish as they push. apelin-environment holds each file to its
/// digest again as it copies it, and refuses another linked repository.
enum AgentPublishRules {
    static let detailKey = "packagePublish"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this publication.
    static func covers(_ publish: DistributionPublishRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.packagePublish.rawValue,
              let detail = asked["detail"]?[detailKey],
              let repository = publish.repository, detail["repository"]?.stringValue == repository,
              let digests = publish.digests, digests.count == publish.files.count,
              case let .array(packages)? = detail["packages"], packages.count == publish.files.count
        else { return false }
        return zip(packages, zip(publish.files, digests)).allSatisfy { package, sent in
            package["file"]?.stringValue == sent.0 && package["digest"]?.stringValue == sent.1
        }
    }

    /// Nil when the session may publish it, else why not; under Confirm the
    /// approval that covers it is spent.
    static func authorize(
        _ publish: DistributionPublishRequest,
        session: String?,
        registry: TaskRegistry,
        artifacts: ArtifactRegistry,
    ) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard let repository = publish.repository, !repository.isEmpty,
              let digests = publish.digests, digests.count == publish.files.count
        else {
            return ApelinError(.badRequest, "an agent's publish names the repository and each package's digest")
        }
        for (file, digest) in zip(publish.files, digests) {
            guard let built = await artifacts.artifact(path: file), InstallDigest.normalized(digest) == built.digest else {
                return ApelinError(
                    .denied,
                    "an agent publishes only packages Apelin's builds made, as they made them: \((file as NSString).lastPathComponent) is not one with that digest; build it again with apelin_project_build",
                )
            }
        }
        guard entry.mode.asks else { return nil }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: { covers(publish, asked: $0) }) else {
            let count = publish.files.count == 1 ? "this package" : "these \(publish.files.count) packages"
            return ApelinError(.denied, "approval required: the user has not approved publishing \(count) to \(repository)")
        }
        return nil
    }
}
