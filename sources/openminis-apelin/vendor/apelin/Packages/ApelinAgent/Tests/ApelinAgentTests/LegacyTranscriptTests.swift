@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// A conversation recorded before the tools were renamed comes back in
/// today's names, so the provider is never sent a call to a tool the
/// request does not offer.
@Suite("Transcripts recorded under the earlier tool names")
struct LegacyTranscriptTests {
    /// A turn as 0.1.8 recorded it, with an MCP server's call beside
    /// Apelin's when `mcp` is set.
    private static func recorded(mcp: Bool = true) -> [Message] {
        let schema: JSONValue = ["type": "object", "properties": [:]]
        let search = "mcp__docs__search"
        var tools = [
            Tool(name: "read_file", description: "Read a project file.", parameters: schema),
            Tool(name: "build", description: "Build the project.", parameters: schema),
        ]
        var calls = [fauxText("Reading it."), fauxToolCall(name: "read_file", arguments: ["path": "Sources/Tweak.m"], id: "call-1")]
        var results: [Message] = [
            .toolResult(ToolResultMessage(toolCallId: "call-1", toolName: "read_file", content: [.text(TextContent(text: "build_id"))])),
        ]
        if mcp {
            tools.append(Tool(name: search, description: "Search the docs.", parameters: schema))
            calls.append(fauxToolCall(name: search, arguments: ["query": "x"], id: "call-2"))
            results.append(.toolResult(ToolResultMessage(toolCallId: "call-2", toolName: search, content: [.text(TextContent(text: "none"))])))
        }
        return [
            .system(SystemMessage(toolsAdded: tools)),
            .user(UserMessage(text: "What does run_code do?")),
            .assistant(fauxAssistantMessage(blocks: calls, stopReason: .toolUse)),
        ] + results + [
            .system(SystemMessage(toolsRemoved: ["build"])),
        ]
    }

    private static func toolNames(_ messages: [Message]) -> [String] {
        messages.flatMap { message -> [String] in
            switch message {
            case let .assistant(assistant):
                assistant.content.compactMap { block in
                    if case let .toolCall(call) = block {
                        return call.name
                    }
                    return nil
                }
            case let .toolResult(result): [result.toolName]
            case let .system(system): (system.toolsAdded ?? []).map(\.name) + (system.toolsRemoved ?? [])
            case .user: []
            }
        }
    }

    @Test
    func `calls, results and declarations take today's names, and nothing else changes`() {
        let recorded = Self.recorded()
        let migrated = LegacyToolNames.migrate(recorded)
        #expect(Self.toolNames(migrated) == [
            "file_read", "apelin_project_build", "mcp__docs__search",
            "file_read", "mcp__docs__search",
            "file_read", "mcp__docs__search",
            "apelin_project_build",
        ])
        #expect(migrated[1] == recorded[1], "the user's words are theirs")
        guard case let .toolResult(result) = migrated[3], case let .text(text)? = result.content.first else {
            Issue.record("the result is still a text result")
            return
        }
        #expect(text.text == "build_id", "a result's text is the tool's")
        #expect(LegacyToolNames.migrate(migrated) == migrated, "a migrated transcript stays as it is")
        #expect(TranscriptTools.currentTools(in: migrated).map(\.name) == ["file_read", "mcp__docs__search"])
    }

    /// End to end: a session reopened on a transcript recorded under the
    /// earlier names sends the provider no call to a tool it does not offer.
    @Test(.timeLimit(.minutes(1)))
    func `a reopened session sends the provider only today's names`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let sent = SentContexts()
        faux.setResponses([.factory { context, _, _, _ in
            await sent.add(context)
            return fauxAssistantMessage("It runs a command.")
        }])
        let configuration = AgentSessionConfiguration(
            project: home.project,
            provider: .registered(faux.getModel()),
            approval: ApprovalPolicy(mode: .relaxed),
            dataRoot: home.dataRoot,
        )
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: configuration.id)
        try await log.writeTranscript(Self.recorded(mcp: false))
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let events = try await session.events(afterSeq: 0)
        try await session.prompt("And now?")
        for await record in events {
            if case .finished = record.event {
                break
            }
        }
        await session.close()
        let context = try #require(await sent.contexts.first)
        let offered = Set((context.tools ?? []).map(\.name))
        let legacy = Set(AgentToolName.legacyNames.keys)
        for message in context.messages {
            guard case let .assistant(assistant) = message else { continue }
            for case let .toolCall(call) in assistant.content {
                #expect(!legacy.contains(call.name), "\(call.name)")
                #expect(offered.contains(call.name), "\(call.name) is offered")
            }
        }
    }
}

private actor SentContexts {
    var contexts: [Context] = []
    func add(_ context: Context) {
        contexts.append(context)
    }
}
