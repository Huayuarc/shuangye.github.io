import ApelinProtocol

/// Toolchain setup and removal, served by apelin-environment. An agent's
/// setup passes the host's own check first (`AgentEnvironmentRules`).
enum ToolchainHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .toolchainStatus, .toolchainCatalog, .toolchainSetDefault:
            return await host.forward(request, to: .environment)
        case .toolchainSetup, .toolchainRemove:
            if let refusal = await agentRefusal(request, host: host) {
                return request.fail(refusal)
            }
            return await host.startTask(request, kind: .environment, role: .environment, resumable: true)
        case .toolchainSelfTest:
            // quick and harmless to run again by hand: not resumed
            return await host.startTask(request, kind: .environment, role: .environment, resumable: false)
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a toolchain operation"))
        }
    }

    /// Nil for the app; for an agent, the refusal of a setup that is not
    /// one from the catalog, or under Confirm one the user did not approve.
    static func agentRefusal(_ request: HostRequest, host: SessionHost) async -> ApelinError? {
        guard case let .worker(.agent, instance) = request.caller else { return nil }
        var entry: AgentSessionTable.Entry?
        if let instance {
            entry = await AgentSessionTable.shared.entry(instance)
        }
        do {
            try await AgentEnvironmentRules.authorize(
                request.request,
                descriptorCount: request.descriptors.count,
                entry: entry,
                registry: host.registry,
            )
            return nil
        } catch {
            return (error as? ApelinError) ?? ApelinError(.badRequest, "\(error)")
        }
    }
}
