import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("apelin_git_create_repository is one gitRepositoryCreate request")
struct RepositoryBackendTests {
    private static let created = GitRepositoryCreateResponse(
        fullName: "someone/clock-tweak",
        cloneURL: "https://github.com/someone/clock-tweak.git",
        url: "https://github.com/someone/clock-tweak",
    )

    private func request(_ fixture: Fixture) -> RepositoryCreateToolRequest {
        RepositoryCreateToolRequest(
            context: fixture.context(),
            owner: nil,
            name: "clock-tweak",
            visibility: .private,
            description: "A clock",
        )
    }

    @Test
    func `the repository goes as gitRepositoryCreate, and the answer names the push that publishes to it`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitRepositoryCreate, reply: Self.created)
        let response = try await fixture.backend.createRepository(request(fixture))
        let sent = try #require(fixture.host.requests(GitRepositoryCreateRequest.self).first)
        #expect(fixture.host.requests.map(\.operation) == [.gitRepositoryCreate])
        #expect(sent.name == "clock-tweak" && sent.visibility == .private && sent.owner == nil && sent.description == "A clock")
        #expect(response.fullName == "someone/clock-tweak" && response.url == "https://github.com/someone/clock-tweak")
        #expect(response.next.contains("git_push with url https://github.com/someone/clock-tweak.git"))
    }

    @Test
    func `without a GitHub sign-in it names Sign In with GitHub, by the reply's reason`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitRepositoryCreate) { _ in
            throw ApelinError(.denied, "no sign-in", reason: .authenticationRequired)
        }
        await #expect {
            _ = try await fixture.backend.createRepository(request(fixture))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.contains("Nothing was created") && message.contains("Sign In with GitHub in Settings ▸ Git")
        }

        // GitHub's own refusal keeps its words.
        fixture.host.on(.gitRepositoryCreate) { _ in
            throw ApelinError(.conflict, "GitHub refused: Repository creation failed.: name already exists on this account")
        }
        await #expect {
            _ = try await fixture.backend.createRepository(request(fixture))
        } throws: { error in
            (error as? ApelinError)?.message.contains("name already exists") == true
        }
    }

    @Test
    func `the approval carries the repository the host matches`() {
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "apelin_git_create_repository", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Creates the empty private repository clock-tweak.",
            detail: .repositoryCreate(RepositoryCreateApproval(owner: nil, name: "clock-tweak", visibility: .private, description: nil)),
            allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let expected: ApelinCore.JSONValue = .object(["repositoryCreate": .object([
            "name": .string("clock-tweak"), "visibility": .string("private"),
        ])])
        #expect(payload["detail"] == expected, "no owner: the account; what is not asked for is not there")
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
