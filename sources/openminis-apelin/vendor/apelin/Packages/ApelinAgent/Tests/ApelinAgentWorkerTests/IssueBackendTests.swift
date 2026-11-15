import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("apelin_git_create_issue is one gitIssueCreate request")
struct IssueBackendTests {
    private func request(_ fixture: Fixture) -> IssueCreateToolRequest {
        IssueCreateToolRequest(
            context: fixture.context(),
            repository: "Lakr233/Irisin",
            title: "The installer stops at 90%",
            body: "Installing a package from the inbox stops at 90%.",
        )
    }

    @Test
    func `the issue goes as gitIssueCreate to the repository named, its text alone`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitIssueCreate, reply: GitIssueCreateResponse(
            number: 7, url: "https://github.com/Lakr233/Irisin/issues/7", repository: "Lakr233/Irisin",
        ))
        let response = try await fixture.backend.createIssue(request(fixture))
        let sent = try #require(fixture.host.requests(GitIssueCreateRequest.self).first)
        #expect(fixture.host.requests.map(\.operation) == [.gitIssueCreate])
        #expect(sent.repository == "Lakr233/Irisin" && sent.title == "The installer stops at 90%")
        #expect(sent.body == "Installing a package from the inbox stops at 90%.")
        #expect(response == IssueCreateToolResponse(repository: "Lakr233/Irisin", issue: 7, url: "https://github.com/Lakr233/Irisin/issues/7"))
    }

    @Test
    func `a refusal says what blocks it and what not to do instead`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitIssueCreate) { _ in
            throw ApelinError(.denied, "no sign-in", reason: .authenticationRequired)
        }
        await #expect {
            _ = try await fixture.backend.createIssue(request(fixture))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.hasPrefix("Nothing was posted") && message.contains("Sign In with GitHub in Settings ▸ Git")
        }

        // GitHub's own refusal keeps its words, and the model is told to
        // report it rather than post elsewhere or through a browser.
        fixture.host.on(.gitIssueCreate) { _ in
            throw ApelinError(.denied, "Issues are turned off on Lakr233/Irisin, so it takes none (GitHub: Issues are disabled for this repo).")
        }
        await #expect {
            _ = try await fixture.backend.createIssue(request(fixture))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.hasPrefix("Nothing was posted on Lakr233/Irisin: Issues are turned off")
                && message.contains("Issues are disabled for this repo")
                && message.contains("never post it to another repository, or through a browser or the screen")
        }
    }

    @Test
    func `the approval carries the issue the host matches`() {
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "apelin_git_create_issue", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Opens this issue on Lakr233/Irisin.",
            detail: .issueCreate(IssueCreateApproval(repository: "Lakr233/Irisin", title: "T", body: "B")),
            allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let expected: ApelinCore.JSONValue = .object(["issueCreate": .object([
            "repository": .string("Lakr233/Irisin"), "title": .string("T"), "body": .string("B"),
        ])])
        #expect(payload["detail"] == expected)
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
