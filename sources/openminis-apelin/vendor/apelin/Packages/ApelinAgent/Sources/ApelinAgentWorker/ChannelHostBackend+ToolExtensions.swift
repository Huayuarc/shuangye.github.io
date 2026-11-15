import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation

/// An agent tool extension's tools → `toolHostOpen` for its session, on
/// the first call of one of them; `toolHostCall`, the files it returns as
/// descriptors; `toolHostClose` when the agent session closes. The host
/// starts the extension as mobile after checking its manifest again and
/// passes the call on: whether it runs is this worker's gate's decision.
public extension ChannelHostBackend {
    func openToolExtension(id: String) async throws -> String {
        try await service.toolHostOpen(id: id).sessionID
    }

    func callToolExtension(_ request: ToolExtensionCallRequest) async throws -> ToolExtensionCallResponse {
        let arguments: ApelinCore.JSONValue
        do {
            arguments = try JSONCoding.decode(ApelinCore.JSONValue.self, from: JSONEncoder().encode(request.arguments))
        } catch {
            throw ApelinError(.badRequest, "the arguments are not JSON the extension takes")
        }
        let (response, files) = try await service.toolHostCall(
            ToolHostCallRequest(
                sessionID: request.sessionID,
                tool: request.tool,
                arguments: arguments,
                timeoutSeconds: request.timeoutSeconds,
            ),
            files: [],
        )
        let failure = response.error.map { error in
            ToolExtensionFailure(
                code: error["code"]?.stringValue ?? "unknown",
                message: error["message"]?.stringValue ?? "the extension gave no message",
            )
        }
        return ToolExtensionCallResponse(
            text: response.text,
            files: files.map { ToolExtensionFile(name: $0.attachment.name, mimeType: $0.attachment.mimeType, descriptor: $0.descriptor) },
            failure: failure,
        )
    }

    func closeToolExtension(sessionID: String) async throws {
        try await service.toolHostClose(sessionID: sessionID)
    }
}
