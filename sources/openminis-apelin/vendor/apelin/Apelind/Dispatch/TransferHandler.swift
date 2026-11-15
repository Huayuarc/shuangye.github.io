import ApelinProtocol

/// Transfer files (.apetc, .apesdk, .apeproj), served by apelin-environment.
/// The app's alone: no worker may call these (CallerPolicy).
enum TransferHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .transferInspect:
            await host.forward(request, to: .environment)
        case .transferExport:
            // Started over from the item itself after a restart.
            await host.startTask(request, kind: .environment, role: .environment, resumable: true)
        case .transferImport:
            // Kept only to be ended with the reason (TaskResume): a project
            // placed before the stop would be placed again under another
            // name, and the app hands the file as a descriptor, which no
            // restart keeps. A toolchain install it made is in its job
            // record, which the same import run again picks up.
            await host.startTask(request, kind: .environment, role: .environment, resumable: true)
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a transfer operation"))
        }
    }
}
