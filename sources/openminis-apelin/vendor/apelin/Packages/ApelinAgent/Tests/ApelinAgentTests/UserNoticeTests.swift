@testable import ApelinAgent
import enum ApelinProtocol.AgentNoticeRules
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("apelin_notification_send")
struct UserNoticeTests {
    private static func runner(
        _ home: TemporaryHome,
        project: ProjectIdentity? = nil,
        mode: ApprovalMode = .confirm,
        gate: ApprovalGate = ApprovalGate { _ in },
        record: (@Sendable (AgentSessionEvent) async throws -> Void)? = nil,
    ) throws -> ToolRunner {
        try ToolRunner(
            sessionID: UUID().uuidString,
            project: project ?? home.project,
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: mode),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            gate: gate,
            record: record,
        )
    }

    private static func notify(_ runner: ToolRunner, _ arguments: JSONValue) async throws -> String {
        let result = try await runner.run(
            .local(.notificationSend),
            toolCallID: UUID().uuidString,
            arguments: arguments,
            cancellation: nil,
            mcp: nil,
        )
        return result.content.compactMap { block -> String? in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }.joined()
    }

    // MARK: Catalog and gate

    @Test
    func `every chat offers it, a body is required, and it never asks`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        for project in [home.project, general] {
            let offered = try Self.runner(home, project: project).agentTools(mcp: []).map(\.name)
            #expect(offered.contains("apelin_notification_send"), "\(project.id)")
        }
        let schema = ToolReason.adding(to: AgentToolName.notificationSend.parameters)
        #expect(schema["required"] == .array(["body", "reason"]))
        #expect(AgentToolName.notificationSend.summary.contains("Never for routine progress"))
        let root = try ScopedRoot(home.projectURL)
        let facts = InvocationFacts(tool: .local(.notificationSend))
        #expect(ApprovalPolicy(mode: .confirm).evaluate(facts, root: root) == .allow(.notRequired))
        #expect(ApprovalPolicy(mode: .relaxed).evaluate(facts, root: root) == .allow(.relaxed))
        // Not a preset the user could take away: no read preset names it.
        #expect(!ApprovalPresets.default.readTools.contains(.notificationSend))
        #expect(ApprovalPolicy(mode: .confirm, presets: ApprovalPresets(readTools: [], systemTools: [], commands: []))
            .evaluate(facts, root: root) == .allow(.notRequired))
    }

    // MARK: The rules

    @Test
    func `a notice is plain and bounded, a few a turn, spaced out`() throws {
        var notices = UserNotices()
        let start = Date()
        let first = try notices.take(["title": " Build\nfailed ", "body": "The header\n\nis missing."], now: start)
        #expect(first.title == "Build failed" && first.body == "The header is missing.")
        #expect(notices.sentMessage.contains("\(AgentNoticeRules.maximumPerTurn - 1) more"))

        #expect(throws: ToolDeniedError.self) { try notices.take(["body": "Too soon."], now: start.addingTimeInterval(5)) }
        var at = start
        for _ in 1 ..< AgentNoticeRules.maximumPerTurn {
            at = at.addingTimeInterval(AgentNoticeRules.minimumInterval)
            _ = try notices.take(["body": "Next."], now: at)
        }
        at = at.addingTimeInterval(AgentNoticeRules.minimumInterval)
        let full = #expect(throws: ToolDeniedError.self) { try notices.take(["body": "One more."], now: at) }
        #expect(full?.message.contains("Say the rest in your reply") == true)
        notices.turnEnded()
        #expect(try notices.take(["body": "A new turn."], now: at).body == "A new turn.")

        var fresh = UserNotices()
        #expect(throws: ToolArgumentError.self) { try fresh.take([:], now: start) }
        #expect(throws: ToolArgumentError.self) { try fresh.take(["body": " \n\t "], now: start) }
        let long = String(repeating: "x", count: AgentNoticeRules.maximumBodyLength + 1)
        #expect(throws: ToolArgumentError.self) { try fresh.take(["body": .string(long)], now: start) }
        let heading = String(repeating: "t", count: AgentNoticeRules.maximumTitleLength + 1)
        #expect(throws: ToolArgumentError.self) { try fresh.take(["title": .string(heading), "body": "Done."], now: start) }
        // None of those counted.
        #expect(try fresh.take(["body": .string(String(repeating: "y", count: AgentNoticeRules.maximumBodyLength))], now: start).title == nil)
    }

    // MARK: Through the runner

    @Test(.timeLimit(.minutes(1)))
    func `the runner records the notice without asking, in Strict mode too`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let asked = EventCollector()
        let recorded = EventCollector()
        let runner = try Self.runner(home, gate: ApprovalGate { await asked.add($0) }) { await recorded.add($0) }
        // An empty title is a title left out.
        let answer = try await Self.notify(runner, ["title": "", "body": "Unlock the phone so I can check the tweak."])
        #expect(answer.hasPrefix("Sent to Apelin as a notification."))
        #expect(await recorded.events == [.notice(title: nil, body: "Unlock the phone so I can check the tweak.")])
        #expect(await asked.events.isEmpty)
        await #expect(throws: ToolDeniedError.self) {
            _ = try await Self.notify(runner, ["body": "Again at once."])
        }
        #expect(await recorded.events.count == 1)

        let unwired = try Self.runner(home)
        await #expect(throws: ToolDeniedError.self) {
            _ = try await Self.notify(unwired, ["body": "Nowhere to go."])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a session's notice is in its log, between the call and its result`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_notification_send", arguments: [
                "reason": "Tell the user the build is done",
                "title": "Build done",
                "body": "The tweak built; installing it next.",
            ])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Done.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Build it")
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        let notice = try #require(events.firstIndex(of: .notice(title: "Build done", body: "The tweak built; installing it next.")))
        let call = try #require(events.firstIndex {
            if case let .toolCallStarted(call) = $0 {
                return call.name == "apelin_notification_send"
            }
            return false
        })
        let result = try #require(events.firstIndex {
            if case let .toolCallFinished(result) = $0 {
                return result.name == "apelin_notification_send" && !result.isError
            }
            return false
        })
        #expect(call < notice && notice < result)
        #expect(!events.contains {
            if case .approvalRequested = $0 {
                return true
            }
            return false
        })
        await session.close()
    }
}
