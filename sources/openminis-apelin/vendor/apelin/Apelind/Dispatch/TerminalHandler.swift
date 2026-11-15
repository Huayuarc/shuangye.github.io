import ApelinProtocol

// PTYs: the host opens them and drops the shell to mobile before exec
// (Session/Terminal). The app only: CallerPolicy gives no worker a terminal.
enum TerminalHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .ptyOpen:
            await request.serve(PtyOpenRequest.self) { open in
                try await host.terminals.open(open)
            }
        case .ptyAttach:
            await attachTerminal(request, host: host)
        case .ptyResize:
            await request.serve(PtyResizeRequest.self) { resize in
                try await host.terminals.resize(resize)
            }
        case .ptyClose:
            await request.serve(PtyCloseRequest.self) { close in
                try await host.terminals.close(close)
            }
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a terminal operation"))
        }
    }

    /// The lifecycle and output events from the registry, and — when asked
    /// for — a socket to the live terminal as descriptor 0.
    private static func attachTerminal(_ request: HostRequest, host: SessionHost) async -> HostReply {
        let attach: PtyAttachRequest
        do {
            attach = try request.decode(PtyAttachRequest.self)
        } catch {
            return request.fail(ApelinError(.badRequest, "\(error)"))
        }
        let (reply, _) = await host.attach(request, PtyAttachRequest.self)
        guard attach.wantsDescriptor, case .success = reply.result else { return (reply, []) }
        do {
            return try await (reply, [host.terminals.descriptor(for: attach.taskID)])
        } catch {
            return request.fail(error)
        }
    }
}
