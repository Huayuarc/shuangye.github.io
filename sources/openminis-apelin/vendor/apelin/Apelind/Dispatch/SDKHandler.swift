import ApelinProtocol

/// The SDK manager, served by apelin-environment. An agent's import passes
/// the host's own check first (`AgentEnvironmentRules`).
enum SDKHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .sdkList, .sdkRemove:
            return await host.forward(request, to: .environment)
        case .sdkImport:
            if let refusal = await ToolchainHandler.agentRefusal(request, host: host) {
                return request.fail(refusal)
            }
            return await host.startTask(request, kind: .environment, role: .environment, resumable: true)
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not an SDK operation"))
        }
    }
}
