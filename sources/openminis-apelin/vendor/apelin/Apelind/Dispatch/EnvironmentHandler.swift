import ApelinProtocol

/// Environment tasks, read and cancelled in the registry. An agent reads
/// only the ones its own session started (its setups, imports, self-tests
/// and git tasks).
enum EnvironmentHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .environmentAttach:
            if case let .worker(.agent, instance) = request.caller {
                guard let instance, let attach = try? request.decode(EnvironmentAttachRequest.self),
                      await AgentSessionTable.shared.started(attach.taskID, session: instance)
                else {
                    return request.fail(ApelinError(.denied, "an agent reads only the environment tasks it started"))
                }
            }
            return await host.attach(request, EnvironmentAttachRequest.self)
        case .environmentCancel:
            return await host.cancel(request, EnvironmentCancelRequest.self)
        default:
            return request.fail(ApelinError(
                .badRequest,
                "\(request.operation.rawValue) is not an environment operation",
            ))
        }
    }
}
