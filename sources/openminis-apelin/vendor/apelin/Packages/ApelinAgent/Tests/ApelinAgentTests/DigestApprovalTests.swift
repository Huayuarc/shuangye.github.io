@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Digest-bound build and install approvals")
struct DigestApprovalTests {
    @Test
    func `changing the mode updates an existing runner in both directions`() async throws {
        let harness = try Harness()
        defer { harness.home.remove() }
        let (_, strict) = try await harness.run(.packageRemove, ["installation_id": "test"])
        #expect(strict.count == 1)
        await harness.runner.setMode(.relaxed)
        let (_, relaxed) = try await harness.run(.packageRemove, ["installation_id": "test"])
        #expect(relaxed.isEmpty)
        await harness.runner.setMode(.confirm)
        let (_, strictAgain) = try await harness.run(.packageRemove, ["installation_id": "test"])
        #expect(strictAgain.count == 1)
    }

    /// A runner whose gate answers each request with `answer` and lets the
    /// mock host record what it relayed.
    final class Harness: Sendable {
        let home: TemporaryHome
        let ledger = MockDigestLedger()
        let backend = MockBackend()
        let events = EventCollector()
        let gate: ApprovalGate
        let runner: ToolRunner

        init(
            mode: ApprovalMode = .confirm,
            onGitWalk: (@Sendable () -> Void)? = nil,
            skills: Bool = false,
        ) throws {
            home = try TemporaryHome()
            let events = events
            gate = ApprovalGate { await events.add($0) }
            var root = try ScopedRoot(home.projectURL)
            root.onGitWalk = onGitWalk
            runner = ToolRunner(
                sessionID: UUID().uuidString,
                project: home.project,
                root: root,
                policy: ApprovalPolicy(mode: mode),
                backend: backend,
                digests: ledger,
                gate: gate,
                skills: skills ? home.dataRoot.skills : nil,
            )
        }

        /// Runs a tool while acting as the app and host: every approval
        /// request is answered with `decision`, and the host records it.
        func run(_ tool: AgentToolName, _ arguments: JSONValue, answering decision: ApprovalDecision = .approve(.once)) async throws -> (AgentToolResult, [ApprovalRequest]) {
            let before = await events.events.count
            let answering = Task {
                var answered: Set<String> = []
                while !Task.isCancelled {
                    for request in await gate.pending where !answered.contains(request.id) {
                        answered.insert(request.id)
                        await ledger.record(request, decision: decision)
                        try? await gate.resolve(request.id, decision: decision)
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            defer { answering.cancel() }
            let result = try await runner.run(.local(tool), toolCallID: UUID().uuidString, arguments: arguments, cancellation: nil, mcp: nil)
            let requests = await events.events.dropFirst(before).compactMap { event -> ApprovalRequest? in
                if case let .approvalRequested(request) = event {
                    return request
                }
                return nil
            }
            return (result, requests)
        }
    }

    @Test
    func `a template build runs; a changed one asks once per digest`() async throws {
        let harness = try Harness()
        defer { harness.home.remove() }

        var (_, asked) = try await harness.run(.projectBuild, [:])
        #expect(asked.isEmpty)

        await harness.ledger.change(.build, to: "build-changed-1")
        (_, asked) = try await harness.run(.projectBuild, [:])
        #expect(asked.count == 1)
        guard case .descriptionChanged(.build, "build-changed-1", _) = asked.first?.detail else {
            Issue.record("expected a digest-bound card"); return
        }
        #expect(asked.first?.allowsSessionScope == false)

        // Same digest: the host's ledger has it, no question.
        (_, asked) = try await harness.run(.projectBuild, [:])
        #expect(asked.isEmpty)

        // Changed again: asks again.
        await harness.ledger.change(.build, to: "build-changed-2")
        (_, asked) = try await harness.run(.projectBuild, [:])
        #expect(asked.count == 1)

        let calls = await harness.backend.calls.map { call -> String in
            guard case let .build(digest, evidence) = call else { return "other" }
            switch evidence {
            case .templateMatch: return "\(digest):template"
            case .digestApproved: return "\(digest):ledger"
            case .user: return "\(digest):user"
            default: return "\(digest):?"
            }
        }
        #expect(calls == ["build-template:template", "build-changed-1:user", "build-changed-1:ledger", "build-changed-2:user"])
    }

    @Test
    func `a denied changed install does not reach the host, and is asked again`() async throws {
        let harness = try Harness()
        defer { harness.home.remove() }
        await harness.ledger.change(.packaging, to: "packaging-changed")
        let arguments: JSONValue = ["artifact_id": "artifact-1", "artifact_digest": "deb-digest-1"]

        await #expect(throws: ToolDeniedError.self) {
            _ = try await harness.run(.packageInstall, arguments, answering: .deny(reason: "not now"))
        }
        #expect(await harness.backend.calls.isEmpty)

        let (_, asked) = try await harness.run(.packageInstall, arguments)
        #expect(asked.count == 1)
        let calls = await harness.backend.calls
        guard case .install("artifact-1", "deb-digest-1", "packaging-changed", .user)? = calls.first else {
            Issue.record("install should carry the artifact and packaging digests: \(calls)"); return
        }
    }

    @Test
    func `Relaxed builds a changed description without asking`() async throws {
        let harness = try Harness(mode: .relaxed)
        defer { harness.home.remove() }
        await harness.ledger.change(.build, to: "anything")
        let (_, asked) = try await harness.run(.projectBuild, [:])
        #expect(asked.isEmpty)
        #expect(await harness.backend.calls == [.build(digest: "anything", evidence: .relaxed)])
    }

    @Test
    func `session-scoped approval covers the identical call only; removal is never remembered`() async throws {
        let harness = try Harness()
        defer { harness.home.remove() }
        var (_, asked) = try await harness.run(.shellRun, ["argv": ["make", "all"]], answering: .approve(.session))
        #expect(asked.count == 1)
        (_, asked) = try await harness.run(.shellRun, ["argv": ["make", "all"]], answering: .approve(.session))
        #expect(asked.isEmpty)
        (_, asked) = try await harness.run(.shellRun, ["argv": ["make", "clean"]], answering: .approve(.once))
        #expect(asked.count == 1)
        (_, asked) = try await harness.run(.shellRun, ["argv": ["make", "all"], "cwd": "Sources"], answering: .approve(.once))
        #expect(asked.count == 1)

        (_, asked) = try await harness.run(.packageRemove, ["installation_id": "inst-1"], answering: .approve(.session))
        #expect(asked.count == 1 && asked.first?.allowsSessionScope == false)
        (_, asked) = try await harness.run(.packageRemove, ["installation_id": "inst-1"], answering: .approve(.once))
        #expect(asked.count == 1)
    }

    /// The session host grants a removal only from `detail.packageRemoval`
    /// in the session's own request (`AgentApprovals.recordInLedger`); a
    /// request without it can be approved but never spent.
    @Test
    func `a package removal asks with the installation it removes`() async throws {
        let harness = try Harness()
        defer { harness.home.remove() }
        let (_, asked) = try await harness.run(.packageRemove, ["installation_id": "inst-1"])
        #expect(asked.count == 1)
        #expect(asked.first?.detail == .packageRemoval(installationID: "inst-1"))
    }

    @Test
    func `a waiting approval resumes on abort, denied`() async throws {
        let harness = try Harness()
        defer { harness.home.remove() }
        let cancellation = CancellationHandle()
        let task = Task {
            try await harness.runner.run(.local(.screenInteract), toolCallID: "t", arguments: ["action": "tap", "x": 1, "y": 2], cancellation: cancellation, mcp: nil)
        }
        while await harness.gate.pending.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        cancellation.cancel(reason: "aborted")
        await #expect(throws: ToolDeniedError.self) { _ = try await task.value }
        #expect(await harness.gate.pending.isEmpty)
        #expect(await harness.backend.calls.isEmpty)
    }
}

@Suite("apelin_package_confirm_loaded that resprings")
struct ConfirmLoadedGateTests {
    @Test
    func `is gated as respring; without respring it is a read`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let resprings = try await harness.runner.gatherFacts(.local(.packageConfirmLoaded), arguments: ["build_id": "B-1", "target": "SpringBoard", "respring": true])
        #expect(resprings.tool == .local(.deviceRespring))
        let reads = try await harness.runner.gatherFacts(.local(.packageConfirmLoaded), arguments: ["build_id": "B-1", "target": "SpringBoard"])
        #expect(reads.tool == .local(.packageConfirmLoaded))
    }
}
