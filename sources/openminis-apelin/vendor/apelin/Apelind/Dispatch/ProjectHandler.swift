import ApelinCore
import ApelinProtocol

/// Extensions, templates and projects, served by apelin-build. A deletion
/// (`projectDelete`) is decided here first (AgentProjectDeleteRules), the
/// project's conversations closed as the app's Delete closes them, and then
/// removed as mobile, bound to the folder the host resolved.
enum ProjectHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if request.operation == .projectRename, case let .worker(.agent, instance) = request.caller {
            guard let rename = try? JSONCoding.decode(ProjectRenameRequest.self, from: request.request.payload) else {
                return request.fail(ApelinError(.badRequest, "projectRename names no project"))
            }
            if let refusal = await AgentProjectRenameRules.authorize(rename, session: instance, home: host.home, registry: host.registry) {
                return request.fail(refusal)
            }
        }
        switch request.operation {
        case .extensionList, .projectCreate, .projectCheck, .projectRename:
            return await host.forward(request, to: .build)
        case .projectDelete:
            return await delete(request, host: host)
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a project operation"))
        }
    }

    private static func delete(_ request: HostRequest, host: SessionHost) async -> HostReply {
        var bound = request
        do {
            let target = try AgentProjectDeleteRules.target(request.decode(ProjectDeleteRequest.self), home: host.home)
            if case let .worker(.agent, instance) = request.caller,
               let refusal = await AgentProjectDeleteRules.authorize(target, session: instance, registry: host.registry)
            {
                return request.fail(refusal)
            }
            try await AgentHandler.closeSessions(ofProject: target.id, host: host)
            bound.request.payload = try JSONCoding.encode(ProjectDeleteRequest(projectID: target.id, projectName: target.name))
        } catch {
            return request.fail(error)
        }
        return await host.forward(bound, to: .build)
    }
}
