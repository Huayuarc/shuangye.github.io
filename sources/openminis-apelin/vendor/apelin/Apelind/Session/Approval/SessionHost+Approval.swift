import ApelinCore
import ApelinProtocol
import Foundation

/// The host's own Confirm-mode decision (Milestone 1 §7, 宿主执行策略): the
/// agent's gate asks the user, and the host checks again, from its private
/// ledger, whatever the agent concluded. Install and removal are checked in
/// InstallBridge; a build here, before the request reaches apelin-build.
///
/// The digests come from apelin-build, the one process that reads the
/// project's description, never from the agent:
/// - `projectCreate`'s answer carries `descriptionDigests` {build, packaging}
///   for the project exactly as the template made it; the host records them
///   as the template baseline (`observe`).
/// - Before an agent's `buildStart` under Confirm, the host asks apelin-build
///   for `projectCheck` and reads `descriptionDigests.build` from its answer,
///   then forwards the build with that digest as `approvedBuildDigest`, which
///   apelin-build holds the description it runs to.
/// - A build's `artifact` event carries `packagingDigest`, which an install
///   is judged by (ArtifactRegistry).
/// A digest the host cannot get is a change: the run is refused until the
/// user approves it.
extension SessionHost {
    /// A refusal for a request the caller may make but not now; nil lets it
    /// through as `request` now reads, which is what goes on to be served.
    func precheck(_ request: inout HostRequest) async -> HostReply? {
        guard case let .worker(.agent, session) = request.caller, request.operation == .buildStart else { return nil }
        var build: BuildStartRequest
        do {
            build = try request.decode(BuildStartRequest.self)
        } catch {
            return request.fail(ApelinError(.badRequest, "\(error)"))
        }
        // Only the host names the digest it approved.
        build.approvedBuildDigest = nil
        if await approvals.mode(session: session).asks, let refusal = await approveBuild(&build, request, session: session) {
            return refusal
        }
        do {
            request.request.payload = try JSONCoding.encode(build)
        } catch {
            return request.fail(ApelinError(.internal, "encoding the build request: \(error)"))
        }
        return nil
    }

    /// Confirm's build check: the description apelin-build reports now must
    /// be the template's or approved; `build` then carries its digest. A
    /// workspace has no description: its build spends the one approval the
    /// user gave for it (AgentExternalBuildRules).
    private func approveBuild(
        _ build: inout BuildStartRequest,
        _ request: HostRequest,
        session: String?,
    ) async -> HostReply? {
        let check = HostRequest(
            request: (try? WireRequest(ProjectCheckRequest(projectID: build.projectID))) ?? request.request,
            descriptors: [],
            caller: .app,
        )
        let (reply, _) = await forward(check, to: .build)
        if case let .success(body) = reply.result,
           let json = try? JSONCoding.decode(JSONValue.self, from: body),
           json["buildSystem"]?.stringValue == BuildSystemKind.external.rawValue
        {
            return await AgentExternalBuildRules.authorize(build, session: session, registry: registry).map(request.fail)
        }
        guard case let .success(body) = reply.result,
              let json = try? JSONCoding.decode(JSONValue.self, from: body),
              let digest = json["descriptionDigests"]?["build"]?.stringValue
        else {
            return request.fail(
                ApelinError(
                    .denied,
                    "approval required: the host could not compute the build description of \(build.projectID), so it cannot tell it matches the template",
                ),
            )
        }
        do {
            guard try await approvals.allows(digest, kind: .build, project: build.projectID) else {
                return request.fail(
                    ApelinError(
                        .denied,
                        "approval required: the build description \(digest) of project \(build.projectID) changed since the template and was never approved",
                    ),
                )
            }
        } catch {
            return request.fail((error as? ApelinError) ?? ApelinError(.internal, "\(error)"))
        }
        build.approvedBuildDigest = digest
        return nil
    }

    /// Learns from answers passing through: the template baseline of a new project.
    func observe(_ request: HostRequest, _ reply: HostReply) async {
        guard request.operation == .projectCreate, case let .success(body) = reply.0.result,
              let json = try? JSONCoding.decode(JSONValue.self, from: body),
              let project = json["projectID"]?.stringValue,
              let digests = json["descriptionDigests"] else { return }
        for kind in ApprovalDescriptionKind.allCases {
            if let digest = digests[kind.rawValue]?.stringValue {
                try? await approvals.recordTemplate(digest, kind: kind, project: project)
            }
        }
    }
}
