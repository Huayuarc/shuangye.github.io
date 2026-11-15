import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("apelin_project_delete is one projectDelete request")
struct ProjectDeleteBackendTests {
    @Test
    func `the project goes as projectDelete with its id and the folder the card named`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.projectDelete, reply: ProjectDeleteResponse(projectID: "p-weather", projectName: "Weather"))
        let response = try await fixture.backend.deleteProject(ProjectDeleteToolRequest(
            context: fixture.context(),
            projectID: "p-weather",
            folder: "Weather",
        ))
        let sent = try #require(fixture.host.requests(ProjectDeleteRequest.self).first)
        #expect(fixture.host.requests.map(\.operation) == [.projectDelete])
        #expect(sent.projectID == "p-weather" && sent.projectName == "Weather")
        #expect(response == ProjectDeleteToolResponse(projectID: "p-weather", folder: "Weather"))
    }

    @Test
    func `the approval carries the project the host matches`() {
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "apelin_project_delete", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Deletes the project Weather.",
            detail: .projectDelete(ProjectDeleteApproval(projectID: "p-weather", folder: "Weather", displayName: "Rain Gauge")),
            allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let expected: ApelinCore.JSONValue = .object(["projectDelete": .object([
            "projectID": .string("p-weather"), "folder": .string("Weather"), "displayName": .string("Rain Gauge"),
        ])])
        #expect(payload["detail"] == expected)
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
