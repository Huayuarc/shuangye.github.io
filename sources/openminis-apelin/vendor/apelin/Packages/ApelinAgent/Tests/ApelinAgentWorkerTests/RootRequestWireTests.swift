import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

/// The worker's half of a root request on the wire. The host binds a root
/// approval to `detail.rootCommand` and compares it with the request's
/// `spec`; Tests/SessionHost/RootRunChecks.swift decodes these same JSON
/// texts (`wireShapes` there), so a change on either side fails one
/// of the two.
@Suite("A root request on the wire")
struct RootRequestWireTests {
    static let shapes: [(invocation: RunCodeInvocation, detail: String, spec: RunCodeSpec)] = [
        (.argv(["irisin-cli", "install", "--yes", "x"]), #"{"argv":{"_0":["irisin-cli","install","--yes","x"]}}"#, .argv(["irisin-cli", "install", "--yes", "x"])),
        (.shell("irisin-cli install --yes x | tee log"), #"{"shell":{"_0":"irisin-cli install --yes x | tee log"}}"#, .script(interpreter: "sh", source: "irisin-cli install --yes x | tee log")),
        (.script(interpreter: "python3", source: "print(1)"), #"{"script":{"interpreter":"python3","source":"print(1)"}}"#, .script(interpreter: "python3", source: "print(1)")),
    ]

    @Test
    func `rootCommand holds the invocation the request is sent with`() throws {
        for (invocation, detail, spec) in Self.shapes {
            let request = ApprovalRequest(
                id: "a", toolCallID: "c", tool: "shell_run", arguments: "{}", workingDirectory: "Sources",
                projectID: "p", fingerprint: "f", reason: "root", detail: .rootCommand(invocation), allowsSessionScope: false,
            )
            let payload = EventRelay.approvalPayload(request)
            let expected = try JSONCoding.decode(ApelinCore.JSONValue.self, from: Data(detail.utf8))
            #expect(payload["detail"]?[RunCodeApproval.rootCommandDetail] == expected, "\(invocation)")
            #expect(payload["detail"]?["command"] == nil)
            #expect(payload["workingDirectory"] == .string("Sources"))
            #expect(ChannelHostBackend.spec(invocation) == spec)
        }
    }

    @Test
    func `asRoot goes on the wire only when the call asked for root`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentRunCode, reply: AgentRunCodeResponse(exitCode: 0, stdout: "", stderr: ""))
        for asRoot in [false, true] {
            _ = try await fixture.backend.runCode(RunCodeRequest(
                context: fixture.context(.user(requestID: "r", fingerprint: "f")),
                invocation: .argv(["id"]),
                workingDirectory: "Sources",
                timeoutSeconds: 10,
                asRoot: asRoot,
            ))
        }
        let sent = fixture.host.requests(AgentRunCodeRequest.self)
        #expect(sent.map(\.asRoot) == [nil, true], "a mobile call carries no asRoot at all")
        #expect(sent.allSatisfy { $0.workingDirectory == "Sources" && $0.approval == .user(approvalID: "r") })
    }
}
