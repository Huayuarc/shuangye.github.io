import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Darwin
import Foundation
import Testing

@Suite("An agent tool extension's tools reach the host's tool sessions")
struct ToolExtensionBackendTests {
    @Test
    func `open, call and close are toolHostOpen, toolHostCall and toolHostClose`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.toolHostOpen, reply: ToolHostOpenResponse(sessionID: "tool-session"))
        let listing = Data("0000000100003f50 T _main\n".utf8)
        fixture.host.on(.toolHostCall) { _ in
            (
                ToolHostCallResponse(text: "1 symbol", attachments: [ToolHostAttachment(
                    descriptor: DescriptorSlot(index: 0),
                    name: "symbols.txt",
                    mimeType: "text/plain",
                    byteCount: listing.count,
                    sha256: "sha256:00",
                )]),
                [descriptor(holding: listing)],
            )
        }
        fixture.host.on(.toolHostClose, reply: Acknowledged())

        #expect(try await fixture.backend.openToolExtension(id: "wiki.qaq.apelin.agent-tools.disassembler") == "tool-session")
        let response = try await fixture.backend.callToolExtension(ToolExtensionCallRequest(
            sessionID: "tool-session",
            tool: "symbols",
            arguments: ["binary": "/usr/lib/dyld", "limit": 10],
            timeoutSeconds: 30,
        ))
        try await fixture.backend.closeToolExtension(sessionID: "tool-session")

        #expect(fixture.host.requests(ToolHostOpenRequest.self).map(\.id) == ["wiki.qaq.apelin.agent-tools.disassembler"])
        let call = try #require(fixture.host.requests(ToolHostCallRequest.self).first)
        #expect(call.sessionID == "tool-session" && call.tool == "symbols" && call.timeoutSeconds == 30)
        #expect(call.arguments == .object(["binary": .string("/usr/lib/dyld"), "limit": .number(10)]))
        #expect(call.attachments.isEmpty, "the worker sends no files")
        #expect(fixture.host.requests(ToolHostCloseRequest.self).map(\.sessionID) == ["tool-session"])

        #expect(response.text == "1 symbol" && response.failure == nil)
        let file = try #require(response.files.first)
        #expect(file.name == "symbols.txt" && file.mimeType == "text/plain")
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = pread(file.descriptor.rawValue, &buffer, buffer.count, 0)
        #expect(Data(buffer.prefix(max(0, count))) == listing, "the host's copy, readable here")
    }

    @Test
    func `the extension's error is its code and message, and a session the host let go is notFound`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.toolHostCall, reply: ToolHostCallResponse(
            text: "",
            error: .object(["code": .string("extensionCrashed"), "message": .string("exited with status 1")]),
        ))
        let response = try await fixture.backend.callToolExtension(ToolExtensionCallRequest(
            sessionID: "tool-session", tool: "disassemble", arguments: [:], timeoutSeconds: nil,
        ))
        #expect(response.failure == ToolExtensionFailure(code: "extensionCrashed", message: "exited with status 1"))

        fixture.host.on(.toolHostCall) { _ in throw ApelinError(.notFound, "no tool session tool-session") }
        let gone = await #expect(throws: ApelinError.self) {
            _ = try await fixture.backend.callToolExtension(ToolExtensionCallRequest(
                sessionID: "tool-session", tool: "disassemble", arguments: [:], timeoutSeconds: nil,
            ))
        }
        #expect(gone?.code == .notFound, "the session's caller opens it again")
    }
}
