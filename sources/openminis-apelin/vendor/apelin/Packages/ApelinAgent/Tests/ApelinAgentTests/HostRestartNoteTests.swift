@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// A conversation the app continues after the session host started again
/// may have last run before a reboot or a renamed jbroot: its first message
/// says so, in the `<system-state>` the user never sees (`SystemState.restartNote`),
/// once, and only when there is history to have gone stale.
@Suite("The note that the host restarted")
struct HostRestartNoteTests {
    /// What the provider was sent, one entry per request.
    private actor Requests {
        private(set) var all: [[Message]] = []

        func add(_ context: Context) {
            all.append(context.messages)
        }
    }

    private static let note = "Apelin's background service has restarted since this conversation last ran"

    private static func text(_ message: Message) -> String? {
        guard case let .user(user) = message else { return nil }
        return user.content.compactMap { block -> String? in
            if case let .text(content) = block {
                return content.text
            }
            return nil
        }.joined()
    }

    /// The `<system-state>` block of each message the model read.
    private static func blocks(_ messages: [Message]) -> [String] {
        messages.compactMap(text).compactMap { text in
            guard let start = text.range(of: SystemState.openingTag),
                  let end = text.range(of: SystemState.closingTag, range: start.upperBound ..< text.endIndex) else { return nil }
            return String(text[start.lowerBound ..< end.upperBound])
        }
    }

    private static func configuration(_ home: TemporaryHome, _ provider: FauxProviderRegistration, id: String, hostRestarted: Bool) -> AgentSessionConfiguration {
        AgentSessionConfiguration(
            id: id,
            project: home.project,
            provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm),
            dataRoot: home.dataRoot,
            installRoot: home.home.path + "/jb",
            hostRestarted: hostRestarted,
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func `a conversation opened again after the host restarted is told so in its next message only, and the app never sees it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        let reply: @Sendable (String) -> FauxResponseStep = { text in
            .factory { context, _, _, _ in
                await requests.add(context)
                return fauxAssistantMessage(text)
            }
        }
        provider.setResponses([reply("Built."), reply("Going on."), reply("Again.")])
        let id = UUID().uuidString
        var session = try await AgentSession(
            configuration: Self.configuration(home, provider, id: id, hostRestarted: false),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Build it.", messageID: UUID())
        await session.waitForIdle()
        await session.close()

        // Opened again by the host that started since, as the app opens it.
        session = try await AgentSession(
            configuration: Self.configuration(home, provider, id: id, hostRestarted: true),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Go on.", messageID: UUID())
        await session.waitForIdle()
        try await session.prompt("And again.", messageID: UUID())
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        await session.close()

        let sent = await requests.all
        try #require(sent.count == 3)
        let blocks = try Self.blocks(#require(sent.last))
        try #require(blocks.count == 3)
        #expect(!blocks[0].contains(Self.note), "the message from before the restart was told it")
        #expect(blocks[1].contains(Self.note), "\(blocks[1])")
        #expect(blocks[1].contains("(install root now: \(home.home.path)/jb)"))
        #expect(blocks[1].contains("the Environment section of the system prompt is current"))
        #expect(!blocks[2].contains(Self.note), "the note was told twice")
        // What the app shows is the text alone.
        for event in events {
            if case let .userMessage(_, text, _) = event {
                #expect(!text.contains(Self.note) && !text.contains(SystemState.openingTag), "the app was shown \(text)")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a conversation with no history is told nothing, whatever the host says`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        provider.setResponses([.factory { context, _, _, _ in
            await requests.add(context)
            return fauxAssistantMessage("Hello.")
        }])
        let session = try await AgentSession(
            configuration: Self.configuration(home, provider, id: UUID().uuidString, hostRestarted: true),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Hello", messageID: UUID())
        await session.waitForIdle()
        await session.close()

        let sent = await requests.all
        let blocks = try Self.blocks(#require(sent.last))
        try #require(blocks.count == 1)
        #expect(!blocks[0].contains(Self.note), "\(blocks[0])")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a queued message that carried the note and was dropped leaves it for the next one`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        provider.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove it", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .factory { context, _, _, _ in
                await requests.add(context)
                return fauxAssistantMessage("One.")
            },
            .factory { context, _, _, _ in
                await requests.add(context)
                return fauxAssistantMessage("Two.")
            },
        ])
        let session = try await AgentSession(
            configuration: Self.configuration(home, provider, id: UUID().uuidString, hostRestarted: false),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("remove it")
        for await record in stream {
            if case .approvalRequested = record.event {
                // due while the run waits, so the queued message carries it
                await session.tellHostRestart()
                try await session.prompt("and keep the logs", messageID: UUID())
                await session.abort()
            }
            if case .finished = record.event {
                break
            }
        }
        await session.waitForIdle()
        try await session.prompt("one")
        await session.waitForIdle()
        try await session.prompt("two")
        await session.waitForIdle()
        await session.close()

        let sent = await requests.all
        try #require(sent.count == 2)
        let one = try #require(Self.blocks(sent[0]).last)
        #expect(one.contains(Self.note), "the dropped message's note was not told again: \(one)")
        let two = try #require(Self.blocks(sent[1]).last)
        #expect(!two.contains(Self.note), "\(two)")
        #expect(!sent[1].compactMap(Self.text).contains { $0.hasSuffix("and keep the logs") }, "the dropped message reached the model")
    }

    @Test
    func `the note names the install root, says where the current state is, and stays short`() {
        let note = SystemState.restartNote(installRoot: "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF", changesBelow: false)
        #expect(note.hasPrefix("- " + Self.note))
        #expect(note.contains("(install root now: /var/containers/Bundle/Application/.jbroot-0123456789ABCDEF)"))
        #expect(note.contains("may be stale"))
        #expect(note.contains("set up, install or import nothing again before checking what is registered now"))
        #expect(SystemState.restartNote(installRoot: nil, changesBelow: true).contains("with the changes below, is current"))
        #expect(!SystemState.restartNote(installRoot: nil, changesBelow: false).contains("install root now"))
        // Paid once a conversation a host's run: about a hundred tokens.
        #expect(note.utf8.count < 600, "\(note.utf8.count) bytes")
        let block = SystemState.make(SystemState.Facts(
            languages: ["en-US"], region: "US", date: Date(), timeZone: .gmt, mode: .confirm,
            changes: ["memory added (all chats): Editor: Prefers tabs."],
            hostRestarted: true, installRoot: "/var/jb",
        ))
        let lines = block.components(separatedBy: "\n")
        let noteLine = lines.firstIndex { $0.hasPrefix("- " + Self.note) }
        let changesLine = lines.firstIndex { $0.hasPrefix("- Changed since you were last told") }
        #expect(noteLine != nil && changesLine != nil && noteLine! < changesLine!, "the changes come after the note: \(block)")
    }
}
