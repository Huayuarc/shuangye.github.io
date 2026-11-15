import ApelinCore
import ApelinProtocol
import Foundation

/// One request as the session host sees it.
struct HostRequest: Sendable {
    var request: WireRequest
    var descriptors: [OwnedDescriptor]
    var caller: Caller

    var operation: AppOperation {
        request.operation
    }

    var requestID: String {
        request.requestID
    }

    /// A request that does not decode comes from an app of another version.
    /// The log names only the operation, never what the request held.
    func decode<R: OperationRequest>(_ type: R.Type) throws -> R {
        do {
            return try request.decode(type)
        } catch {
            NSLog("apelind-session: could not read %@", operation.rawValue)
            throw ApelinError(
                .badRequest,
                """
                Apelin could not read this request. Reinstall Apelin with your preferred package manager, \
                then try again.
                """,
            )
        }
    }
}

typealias HostReply = (WireReply, [OwnedDescriptor])

extension HostRequest {
    /// An `ApelinError` goes out as it is; anything else becomes `.internal`.
    func fail(_ error: any Error) -> HostReply {
        if let error = error as? ApelinError {
            return (.failure(requestID, error), [])
        }
        NSLog("apelind-session: %@ failed: %@", operation.rawValue, String(describing: error))
        return (.failure(requestID, ApelinError(.internal)), [])
    }

    /// Decodes the request as `R`, runs `body`, encodes its answer; thrown
    /// errors become the reply's error.
    func serve<R: OperationRequest>(_: R.Type, _ body: (R) async throws -> R.Response) async -> HostReply {
        do {
            return try await (.success(requestID, body(decode(R.self))), [])
        } catch {
            return fail(error)
        }
    }
}

/// Each `Apelind/Dispatch/<Domain>Handler.swift` is one of these.
protocol DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply
}

/// Routes a request to its domain's handler, after the caller policy and
/// the host's own approval check (Session/Approval/SessionHost+Approval.swift).
enum Dispatcher {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        guard CallerPolicy.allows(request.caller, request.operation) else {
            return request.fail(ApelinError(.denied, "\(request.operation.rawValue) is not available to this caller"))
        }
        var request = request
        if let refusal = await host.precheck(&request) {
            return refusal
        }
        let reply = await route(request, host: host)
        await host.observe(request, reply)
        return reply
    }

    private static func route(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation.domain {
        // apelind answers hello itself; one that reaches the host is a bug.
        case .hello: request.fail(ApelinError(.badRequest, "hello is answered by apelind"))
        case .toolchain: await ToolchainHandler.handle(request, host: host)
        case .sdk: await SDKHandler.handle(request, host: host)
        case .environment: await EnvironmentHandler.handle(request, host: host)
        case .project: await ProjectHandler.handle(request, host: host)
        case .build: await BuildHandler.handle(request, host: host)
        case .install: await InstallHandler.handle(request, host: host)
        case .files: await FilesHandler.handle(request, host: host)
        case .terminal: await TerminalHandler.handle(request, host: host)
        case .logs: await LogsHandler.handle(request, host: host)
        case .diagnostics: await DiagnosticsHandler.handle(request, host: host)
        case .agent: await AgentHandler.handle(request, host: host)
        case .toolHost: await ToolHostHandler.handle(request, host: host)
        case .transfer: await TransferHandler.handle(request, host: host)
        case .git: await GitHandler.handle(request, host: host)
        case .distribution: await DistributionHandler.handle(request, host: host)
        }
    }
}
