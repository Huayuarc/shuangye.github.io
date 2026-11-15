@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAI
import Testing

/// apelin_project_rename: the session's own project's displayName without
/// asking, as the file tools may write it; another project's only as the
/// user approves, every time; an automatic rename for the own project only.
@Suite("Project rename")
struct ProjectRenameToolTests {
    private static let other = try! ProjectIdentity(id: "6f1c5b0e-0000-4000-8000-00000000beef", name: ProjectName("Weather"))

    @Test(.timeLimit(.minutes(1)))
    func `the session's own project is renamed without asking, automatically too`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (_, asked) = try await harness.run(.projectRename, ["display_name": "Lock Screen Clock"])
        let (_, automatic) = try await harness.run(.projectRename, ["display_name": "Clock", "automatic": true])
        #expect(asked.isEmpty && automatic.isEmpty)
        #expect(await harness.backend.calls == [
            .renameProject(projectID: harness.home.project.id, displayName: "Lock Screen Clock", automatic: false),
            .renameProject(projectID: harness.home.project.id, displayName: "Clock", automatic: true),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func `another project's rename asks every time, naming it, and never for the session`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.addProject(Self.other)
        let (_, asked) = try await harness.run(.projectRename, ["display_name": "Rain", "project": "Weather"])
        guard case let .projectRename(rename)? = asked.first?.detail else {
            Issue.record("the card names the rename")
            return
        }
        #expect(rename == ProjectRenameApproval(projectID: Self.other.id, folder: "Weather", currentName: "Weather", displayName: "Rain"))
        #expect(asked.first?.allowsSessionScope == false)
        let (_, again) = try await harness.run(.projectRename, ["display_name": "Rain", "project": .string(Self.other.id)], answering: .approve(.session))
        #expect(again.count == 1, "a session approval does not carry over")
        #expect(await harness.backend.calls.filter {
            $0 == .renameProject(projectID: Self.other.id, displayName: "Rain", automatic: false)
        }.count == 2)

        await #expect(throws: ToolArgumentError.self) {
            _ = try await harness.run(.projectRename, ["display_name": "Rain", "project": "Weather", "automatic": true])
        }
        let relaxed = try DigestApprovalTests.Harness(mode: .relaxed)
        defer { relaxed.home.remove() }
        await relaxed.backend.addProject(Self.other)
        let (_, relaxedAsked) = try await relaxed.run(.projectRename, ["display_name": "Rain", "project": "Weather"])
        #expect(relaxedAsked.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a name that is not one plain line of at most 80 is refused before asking, and General Chat names its project`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        for bad in ["", "Bell\u{7}", "Two\nlines", String(repeating: "x", count: 81)] {
            await #expect(throws: ToolArgumentError.self, "\(bad)") {
                _ = try await harness.run(.projectRename, ["display_name": .string(bad)])
            }
        }
        #expect(await harness.backend.calls.isEmpty)
        #expect(await harness.events.events.isEmpty)

        let id = UUID().uuidString
        let general = try ToolRunner(
            sessionID: UUID().uuidString,
            project: ProjectIdentity(id: "temporary:" + id, name: ProjectName(id)),
            root: ScopedRoot(harness.home.projectURL),
            policy: ApprovalPolicy(mode: .relaxed),
            backend: harness.backend,
            digests: harness.ledger,
            gate: ApprovalGate { _ in },
        )
        await #expect(throws: ToolArgumentError.self) {
            _ = try await general.run(.local(.projectRename), toolCallID: "c", arguments: ["display_name": "Clock"], cancellation: nil, mcp: nil)
        }
    }

    @Test
    func `it is a project edit offered in every chat`() {
        #expect(AgentToolName.projectRename.risk == .writeProject)
        #expect(!AgentToolName.projectRename.isProjectOnly)
    }
}
