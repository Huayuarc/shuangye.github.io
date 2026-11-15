import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

/// The worker's half of Ask Before Using the Screen on the wire. The host
/// matches an agent's readUITree, uiAction and agentRunCode to the
/// `detail.screenControl` of the session's own `approvalRequested`
/// (AgentScreenRules); Tests/SessionHost/ScreenConsentChecks.swift decodes
/// these same JSON texts (`wireShapes` there), so a change on either side
/// fails one of the two.
@Suite("A screen card on the wire")
struct ScreenRequestWireTests {
    static let shapes: [(use: ScreenControlApproval, detail: String)] = [
        (.readTree(targetID: nil), #"{"screenControl":{"operation":"readUITree","request":{}}}"#),
        (
            .readTree(targetID: "com.apple.Preferences"),
            #"{"screenControl":{"operation":"readUITree","request":{"targetID":"com.apple.Preferences"}}}"#,
        ),
        (
            .interact(targetID: nil, action: .tap(x: 10, y: 20.5)),
            #"{"screenControl":{"operation":"uiAction","request":{"action":{"tap":{"x":10,"y":20.5}}}}}"#,
        ),
        (
            .interact(targetID: "com.apple.mobilesafari", action: .tapElement(id: "text:Done")),
            #"{"screenControl":{"operation":"uiAction","request":{"action":{"tapElement":{"text":"Done"}},"targetID":"com.apple.mobilesafari"}}}"#,
        ),
        (
            .command(.argv(["icli", "url", "open", "https://example.com"]), asRoot: false),
            #"{"command":{"argv":{"_0":["icli","url","open","https://example.com"]}},"screenControl":{"operation":"agentRunCode"}}"#,
        ),
        (
            .command(.shell("icli screen info | head"), asRoot: true),
            #"{"rootCommand":{"shell":{"_0":"icli screen info | head"}},"screenControl":{"operation":"agentRunCode"}}"#,
        ),
    ]

    private static func request(_ detail: ApprovalDetail, tool: String) -> ApprovalRequest {
        ApprovalRequest(
            id: "a", toolCallID: "c", tool: tool, arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "screen", detail: detail, allowsSessionScope: false,
        )
    }

    @Test
    func `screenControl names the request as the host is asked for it`() throws {
        for (use, detail) in Self.shapes {
            let payload = EventRelay.approvalPayload(Self.request(.screenControl(use), tool: "apelin_screen_interact"))
            let expected = try JSONCoding.decode(ApelinCore.JSONValue.self, from: Data(detail.utf8))
            #expect(payload["detail"] == expected, "\(use)")
        }
    }

    @Test
    func `an element with nothing to tap it by names no request, so no approval covers it`() {
        let use = ScreenControlApproval.interact(targetID: nil, action: .tapElement(id: "index:3"))
        let payload = EventRelay.approvalPayload(Self.request(.screenControl(use), tool: "apelin_screen_interact"))
        #expect(payload["detail"]?[ScreenConsent.detailKey]?["operation"] == .string("uiAction"))
        #expect(payload["detail"]?[ScreenConsent.detailKey]?["request"] == nil)
    }

    @Test
    func `the action the card names is the one the backend sends`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse())
        let action = ApelinAgent.UIAction.tapElement(id: "text:Done")
        _ = try await fixture.backend.uiAction(ApelinAgent.UIActionRequest(
            context: fixture.context(.user(requestID: "r", fingerprint: "f")),
            targetID: "com.apple.mobilesafari",
            action: action,
        ))
        let sent = try #require(fixture.host.requests(ApelinProtocol.UIActionRequest.self).first)
        let payload = EventRelay.approvalPayload(Self.request(
            .screenControl(.interact(targetID: "com.apple.mobilesafari", action: action)),
            tool: "apelin_screen_interact",
        ))
        let shown = try #require(payload["detail"]?[ScreenConsent.detailKey]?["request"])
            .decode(ApelinProtocol.UIActionRequest.self)
        #expect(shown.targetID == sent.targetID && shown.action == sent.action)
    }
}
