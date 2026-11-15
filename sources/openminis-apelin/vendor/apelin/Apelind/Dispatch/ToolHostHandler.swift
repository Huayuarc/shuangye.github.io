import ApelinProtocol

/// Agent tool extensions, started by the host from their installed manifests
/// as mobile (Session/ToolHost). A session is its opener's.
enum ToolHostHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .toolHostOpen:
            return await request.serve(ToolHostOpenRequest.self) { open in
                try await host.toolHosts.open(open, caller: request.caller)
            }
        case .toolHostCall:
            // Files go both ways as descriptors beside the envelope.
            do {
                let call = try request.decode(ToolHostCallRequest.self)
                let (response, descriptors) = try await host.toolHosts.call(
                    call,
                    descriptors: request.descriptors,
                    caller: request.caller,
                )
                return (.success(request.requestID, response), descriptors)
            } catch {
                return request.fail(error)
            }
        case .toolHostClose:
            return await request.serve(ToolHostCloseRequest.self) { close in
                try await host.toolHosts.close(close, caller: request.caller)
            }
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a toolhost operation"))
        }
    }
}
