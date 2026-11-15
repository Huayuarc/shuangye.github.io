import ApelinProtocol

/// Install through irisind, managed removal and its list, respring and the
/// approval ledger's read side: the host's own work (Session/Install/InstallBridge,
/// Session/Approval/ApprovalLedger), never a worker's.
enum InstallHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .installPackage:
            await request.serve(InstallPackageRequest.self) { install in
                try await host.install.install(install, caller: request.caller)
            }
        case .removePackage:
            await request.serve(RemovePackageRequest.self) { remove in
                try await host.install.remove(remove, caller: request.caller)
            }
        case .installationList:
            await request.serve(InstallationListRequest.self) { query in
                try await host.install.list(query, caller: request.caller)
            }
        case .respring:
            await request.serve(RespringRequest.self) { _ in
                try await host.install.respring()
                return Acknowledged()
            }
        case .approvalDigestState:
            await request.serve(ApprovalDigestStateRequest.self) { query in
                try await host.approvals.state(of: query.digest, kind: query.kind, project: query.projectID)
            }
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not an install operation"))
        }
    }
}
