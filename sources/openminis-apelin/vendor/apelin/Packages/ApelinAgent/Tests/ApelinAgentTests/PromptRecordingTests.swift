@testable import ApelinAgent
import Darwin
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// The app shows a sent message from its `prompt` or `queued` event, so the
/// session records it before reading what changed for its `<system-state>`;
/// the model still reads that change in the message.
@Suite("Prompt recording")
struct PromptRecordingTests {
    @Test(.timeLimit(.minutes(1)))
    func `a message is recorded before a slow refresh, which its turn still reads`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let seen = SystemPrompts()
        let messages = SystemPrompts()
        faux.setResponses([.factory { context, _, _, _ in
            await seen.add(context.systemPrompt)
            // the newest user message; kwwk's tool declaration may follow it
            let user = context.messages.last {
                if case .user = $0 {
                    true
                } else {
                    false
                }
            }
            if case let .user(user)? = user, case let .text(text)? = user.content.first {
                await messages.add(text.text)
            }
            return fauxAssistantMessage("Done.")
        }])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let id = UUID()
        let refresh = try SlowRefresh(home)
        let sending = Task { try await session.prompt("Hello", messageID: id) }

        let records = try await recorded(in: session) { $0 == .userMessage(id: id, text: "Hello", attachments: []) }
        #expect(records != nil, "the message waited for the system prompt")
        #expect(records?.contains { $0.event == .messageStarted } == false)
        try refresh.saveMemory("fresh-memory-body")
        refresh.release()

        try await sending.value
        await session.waitForIdle()
        // a change after the session opened is the message's delta, never the prompt's
        #expect(await messages.all.last??.contains("memory added (all chats): ") == true)
        #expect(await messages.all.last??.contains("fresh-memory-body") == true)
        #expect(await seen.all.last??.contains("fresh-memory-body") == false)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a message sent during a run is recorded as queued before a slow refresh`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        faux.setResponses([
            .factory { _, _, _, _ in
                start.yield()
                for await _ in released {
                    break
                }
                return fauxAssistantMessage("First.")
            },
            .message(fauxAssistantMessage("Second.")),
        ])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.prompt("First", messageID: UUID())
        for await _ in started {
            break
        }
        let id = UUID()
        let refresh = try SlowRefresh(home)
        let sending = Task { try await session.prompt("Second", messageID: id) }

        let records = try await recorded(in: session) { $0 == .userMessageQueued(id: id, text: "Second", attachments: []) }
        #expect(records != nil, "the queued message waited for the system prompt")
        refresh.release()
        try await sending.value
        release.yield()
        await session.waitForIdle()

        let all = try await session.log.records(afterSeq: 0)
        #expect(all.contains { $0.event == .userMessage(id: id, text: "Second", attachments: []) }, "the run took it")
        await session.close()
    }

    @Test
    func `an unchanged model choice is not resolved again, and a signed-out one is refused`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let key = OAuthCredentials(access: "key", refresh: "", expires: 0, extras: ["baseUrl": .string("http://127.0.0.1:9/v1")])
        let source = CountingCredentialSource([CredentialProviderID.openAICompatible: key])
        let provider = ProviderConfiguration.stored(storeID: CredentialProviderID.openAICompatible, model: "test-model")
        let session = try await AgentSession(configuration: AgentSessionConfiguration(project: home.project, provider: provider, approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot), backend: MockBackend(), digests: MockDigestLedger(), credentials: source)

        var reads = await source.reads
        try await session.configure(provider: provider, thinking: .high, credentials: source)
        #expect(await source.reads == reads + 1, "only the stored sign-in is read again")

        var changed = key
        changed.extras["baseUrl"] = .string("http://127.0.0.1:10/v1")
        await source.store(changed, for: CredentialProviderID.openAICompatible)
        reads = await source.reads
        try await session.configure(provider: provider, thinking: .high, credentials: source)
        #expect(await source.reads > reads + 1, "a new sign-in is resolved again")

        await source.remove(CredentialProviderID.openAICompatible)
        await #expect(throws: ProviderResolutionError.missingCredentials(CredentialProviderID.openAICompatible)) {
            try await session.configure(provider: provider, thinking: .high, credentials: source)
        }
        await session.close()
    }

    /// The session's records once one matches, or nil after five seconds.
    private func recorded(
        in session: AgentSession,
        where matches: (AgentSessionEvent) -> Bool,
    ) async throws -> [SessionEventRecord]? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let records = try await session.log.records(afterSeq: 0)
            if records.contains(where: { matches($0.event) }) {
                return records
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}

/// Holds the memory store's lock, which the system prompt's refresh takes
/// to read memories, its last read: a disk as slow as the test wants.
private final class SlowRefresh {
    private let folder: URL
    private var descriptor: Int32

    init(_ home: TemporaryHome) throws {
        folder = home.dataRoot.url
        descriptor = open(folder.appendingPathComponent("memories.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
    }

    /// Writes one memory as the store would, under the lock held here.
    func saveMemory(_ body: String) throws {
        let record = #"{"body":"\#(body)","id":"\#(UUID().uuidString.lowercased())","title":"Fresh"}"#
        let snapshot = #"{"records":[\#(record)],"revision":"\#(UUID().uuidString.lowercased())"}"#
        try Data(snapshot.utf8).write(to: folder.appendingPathComponent("memories.json"), options: .atomic)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

private actor SystemPrompts {
    var all: [String?] = []

    func add(_ prompt: String?) {
        all.append(prompt)
    }
}

/// A credential store that counts its reads.
private actor CountingCredentialSource: CredentialSource {
    private var entries: [String: OAuthCredentials]
    private(set) var reads = 0

    init(_ entries: [String: OAuthCredentials]) {
        self.entries = entries
    }

    func providerIds() -> [String] {
        entries.keys.sorted()
    }

    func credentials(for providerId: String) -> OAuthCredentials? {
        reads += 1
        return entries[providerId]
    }

    func store(_ credentials: OAuthCredentials, for providerID: String) {
        entries[providerID] = credentials
    }

    func remove(_ providerID: String) {
        entries.removeValue(forKey: providerID)
    }
}
