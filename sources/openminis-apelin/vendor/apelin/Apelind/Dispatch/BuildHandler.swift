import ApelinProtocol

/// Builds, served by apelin-build. One process per build is the plan;
/// pass a per-build `instance` to `startTask` when the worker is ready for it.
enum BuildHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .buildStart:
            await host.startTask(request, kind: .build, role: .build, resumable: true)
        case .buildAttach:
            await host.attach(request, BuildAttachRequest.self)
        case .buildCancel:
            await host.cancel(request, BuildCancelRequest.self)
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a build operation"))
        }
    }
}
