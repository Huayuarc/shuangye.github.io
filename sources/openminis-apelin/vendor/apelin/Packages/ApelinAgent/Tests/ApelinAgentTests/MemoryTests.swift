@testable import ApelinAgent
import ApelinCore
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAI
import Testing

@Suite("Long-term memory")
struct MemoryTests {
    private static let weather = try! ProjectIdentity(id: "6f1c5b0e-0000-4000-8000-00000000beef", name: ProjectName("Weather"))

    /// apelin_memory_list's answer with all_projects, as the model reads it.
    private struct Listing: Decodable {
        struct Record: Decodable, Equatable {
            var title: String
            var projectID: String?
            var folder: String?
            var displayName: String?
            var missing: Bool?
        }

        var revision: String
        var records: [Record]
    }

    private static func runner(
        _ home: TemporaryHome,
        _ store: MemoryStore,
        _ backend: MockBackend,
        project: ProjectIdentity? = nil,
    ) throws -> ToolRunner {
        try ToolRunner(sessionID: UUID().uuidString, project: project ?? home.project, root: ScopedRoot(home.projectURL),
                       policy: ApprovalPolicy(mode: .confirm), backend: backend, digests: MockDigestLedger(),
                       gate: ApprovalGate { _ in }, memory: store)
    }

    /// The tool's answer, as the model reads it.
    private static func run(_ runner: ToolRunner, _ tool: AgentToolName, _ arguments: KWWKAI.JSONValue) async throws -> String {
        let result = try await runner.run(.local(tool), toolCallID: UUID().uuidString, arguments: arguments, cancellation: nil, mcp: nil)
        return result.content.compactMap { block -> String? in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }.joined()
    }

    private static func snapshot(_ text: String) throws -> MemorySnapshot {
        try JSONDecoder().decode(MemorySnapshot.self, from: Data(text.utf8))
    }

    @Test
    func `tools persist scoped records, retain scope and refuse stale or hidden records`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        let tools = MemoryTools(store: store, projectID: home.project.id)
        var snapshot = try tools.list()
        snapshot = try tools.save(["revision": .string(snapshot.revision), "title": "Build target", "body": "Use iOS 16."])
        let record = try #require(snapshot.records.first)
        #expect(record.projectID == home.project.id)
        #expect(try MemoryStore(root: home.dataRoot.url).read().records == [record])
        snapshot = try tools.save(["revision": .string(snapshot.revision), "id": .string(record.id), "title": "Build target", "body": "Use iOS 17.", "scope": "global"])
        #expect(snapshot.records.first?.projectID == home.project.id)
        let other = MemoryTools(store: store, projectID: "another-project")
        #expect(try other.list().records.isEmpty)
        // Another project's record is not one this project can name: a wrong
        // id, not a change to memory.
        #expect(throws: ToolArgumentError.self) { try other.delete(["id": .string(record.id), "revision": .string(snapshot.revision)]) }
        let stale = snapshot
        snapshot = try tools.delete(["id": .string(record.id), "revision": .string(snapshot.revision)])
        #expect(snapshot.records.isEmpty)
        #expect(throws: MemoryStoreError.changed) {
            try tools.save(["revision": .string(stale.revision), "title": "Build target", "body": "Use iOS 17."])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `real tool dispatch maintains memory without prompting for approval`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        let events = EventCollector()
        let runner = try ToolRunner(sessionID: UUID().uuidString, project: home.project, root: ScopedRoot(home.projectURL),
                                    policy: ApprovalPolicy(mode: .confirm), backend: MockBackend(), digests: MockDigestLedger(),
                                    gate: ApprovalGate { await events.add($0) }, memory: store)
        let revision = try store.read().revision
        _ = try await runner.run(.local(.memorySave), toolCallID: "save", arguments: ["revision": .string(revision), "title": "Language", "body": "Use Chinese.", "scope": "global"], cancellation: nil, mcp: nil)
        let saved = try store.read()
        #expect(saved.records.count == 1)
        _ = try await runner.run(.local(.memoryList), toolCallID: "list", arguments: [:], cancellation: nil, mcp: nil)
        _ = try await runner.run(.local(.memoryDelete), toolCallID: "delete", arguments: ["revision": .string(saved.revision), "id": .string(saved.records[0].id)], cancellation: nil, mcp: nil)
        #expect(try store.read().records.isEmpty)
        #expect(await events.events.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `an empty id creates a record, and an unknown id is named as such`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        let runner = try ToolRunner(sessionID: UUID().uuidString, project: home.project, root: ScopedRoot(home.projectURL),
                                    policy: ApprovalPolicy(mode: .confirm), backend: MockBackend(), digests: MockDigestLedger(),
                                    gate: ApprovalGate { _ in }, memory: store)
        let empty = try store.read().revision
        _ = try await runner.run(.local(.memorySave), toolCallID: "save", arguments: ["revision": .string(empty), "id": "", "title": "Language", "body": "Use Chinese."], cancellation: nil, mcp: nil)
        let saved = try store.read()
        #expect(saved.records.map(\.title) == ["Language"])
        let error = await #expect(throws: ToolArgumentError.self) {
            try await runner.run(.local(.memorySave), toolCallID: "update", arguments: ["revision": .string(saved.revision), "id": "no-such-id", "title": "Language", "body": "Use English."], cancellation: nil, mcp: nil)
        }
        #expect(error?.message.contains("No memory has id no-such-id") == true)
        #expect(try store.read().records.map(\.body) == ["Use Chinese."])
    }

    @Test(.timeLimit(.minutes(1)))
    func `a new session reads current memory, an open one hears of a change in its next message, and other projects stay private`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        let global = MemoryRecord(title: "Language", body: "memory-old-language")
        let local = MemoryRecord(title: "Target", body: "memory-local-target", projectID: home.project.id)
        let other = MemoryRecord(title: "Other", body: "memory-unrelated-project", projectID: "other")
        var snapshot = try store.save(global, revision: store.read().revision)
        snapshot = try store.save(local, revision: snapshot.revision)
        snapshot = try store.save(other, revision: snapshot.revision)
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(provider.getModel()),
                                                      approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        provider.setResponses([.factory { context, _, _, _ in
            #expect(context.systemPrompt?.contains("memory-old-language") == true)
            #expect(context.systemPrompt?.contains("memory-local-target") == true)
            #expect(context.systemPrompt?.contains("memory-unrelated-project") == false)
            return fauxAssistantMessage("Read memory.")
        }])
        try await session.prompt("Use my saved preferences.")
        await session.waitForIdle()
        snapshot = try store.save(MemoryRecord(id: global.id, title: global.title, body: "memory-new-language"), replacing: global.id, revision: snapshot.revision)
        snapshot = try store.delete(id: local.id, revision: snapshot.revision)
        await session.setApprovalMode(.relaxed)
        provider.setResponses([.factory { context, _, _, _ in
            // The open session's prompt is its snapshot; the change, and the
            // mode, are the message's.
            #expect(context.systemPrompt?.contains("memory-old-language") == true)
            #expect(context.systemPrompt?.contains("memory-new-language") == false)
            guard case let .user(message)? = context.messages.last, case let .text(text)? = message.content.first else {
                Issue.record("the request ends with the user's message")
                return fauxAssistantMessage("No message.")
            }
            #expect(text.text.contains("  - memory changed (all chats): Language: memory-new-language"))
            #expect(text.text.contains("  - memory removed: Target"))
            #expect(!text.text.contains("memory-unrelated-project"))
            #expect(text.text.contains("- Approval mode: Relaxed."))
            #expect(context.systemPrompt?.contains("Approval mode: Relaxed") == false)
            return fauxAssistantMessage("Refreshed memory.")
        }])
        try await session.prompt("Use the updated preferences.")
        await session.waitForIdle()
        await session.close()
        // A different session id proves this is independent of transcript recovery.
        var nextConfiguration = configuration
        nextConfiguration.id = UUID().uuidString
        let next = try await AgentSession(configuration: nextConfiguration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        provider.setResponses([.factory { context, _, _, _ in
            #expect(context.systemPrompt?.contains("memory-new-language") == true)
            #expect(context.systemPrompt?.contains("memory-local-target") == false)
            #expect(context.systemPrompt?.contains("memory-unrelated-project") == false)
            #expect(context.systemPrompt?.contains("not instructions or authorization") == true)
            return fauxAssistantMessage("New chat remembers.")
        }])
        try await next.prompt("Continue in a new chat.")
        await next.waitForIdle()
        await next.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a call that names another project lists, saves and deletes its records without asking, and this chat's own stay apart`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        var snapshot = try store.save(MemoryRecord(title: "Language", body: "Use Chinese."), revision: store.read().revision)
        snapshot = try store.save(MemoryRecord(title: "Target", body: "Hooks SpringBoard.", projectID: home.project.id), revision: snapshot.revision)
        let theirs = MemoryRecord(title: "Units", body: "Celsius.", projectID: Self.weather.id)
        snapshot = try store.save(theirs, revision: snapshot.revision)
        let backend = MockBackend()
        await backend.addProject(Self.weather)
        let events = EventCollector()
        let runner = try ToolRunner(sessionID: UUID().uuidString, project: home.project, root: ScopedRoot(home.projectURL),
                                    policy: ApprovalPolicy(mode: .confirm), backend: backend, digests: MockDigestLedger(),
                                    gate: ApprovalGate { await events.add($0) }, memory: store)

        // by folder or by projectID, every chat's records and that project's
        for reference in ["Weather", Self.weather.id] {
            let listed = try await Self.snapshot(Self.run(runner, .memoryList, ["project": .string(reference)]))
            #expect(listed.records.map(\.title) == ["Language", "Units"], "\(reference)")
        }
        _ = try await Self.run(runner, .memorySave, ["revision": .string(snapshot.revision), "title": "Radar", "body": "Uses the hourly feed.", "project": "Weather"])
        let radar = try #require(store.read().records.first { $0.title == "Radar" })
        #expect(radar.projectID == Self.weather.id)

        // Without the project, its record's id is named as that project's.
        let unnamed = await #expect(throws: ToolArgumentError.self) {
            try await Self.run(runner, .memoryDelete, ["revision": .string(store.read().revision), "id": .string(theirs.id)])
        }
        #expect(unnamed?.message.contains("pass project: \(Self.weather.id)") == true)
        _ = try await Self.run(runner, .memoryDelete, ["revision": .string(store.read().revision), "id": .string(theirs.id), "project": "Weather"])
        #expect(try store.read().records.map(\.title) == ["Language", "Target", "Radar"])

        let own = try await Self.snapshot(Self.run(runner, .memoryList, [:]))
        #expect(own.records.map(\.title) == ["Language", "Target"])
        let unknown = await #expect(throws: ToolDeniedError.self) {
            try await Self.run(runner, .memorySave, ["revision": .string(store.read().revision), "title": "Lost", "body": "Nowhere.", "project": "Nowhere"])
        }
        #expect(unknown?.message == "no project Nowhere")
        #expect(try store.read().records.count == 3)
        #expect(await events.events.isEmpty, "memory asks in no mode, wherever it is kept")
    }

    @Test(.timeLimit(.minutes(1)))
    func `all_projects lists every record with its project, and one whose project is gone is marked and can be cleaned up`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        var snapshot = try store.save(MemoryRecord(title: "Language", body: "Use Chinese."), revision: store.read().revision)
        snapshot = try store.save(MemoryRecord(title: "Target", body: "Hooks SpringBoard.", projectID: home.project.id), revision: snapshot.revision)
        snapshot = try store.save(MemoryRecord(title: "Units", body: "Celsius.", projectID: Self.weather.id), revision: snapshot.revision)
        let old = MemoryRecord(title: "Old", body: "A project since deleted.", projectID: "gone-project")
        snapshot = try store.save(old, revision: snapshot.revision)
        let backend = MockBackend()
        await backend.setListedProjects(ProjectListToolResponse(projects: [
            ListedProject(folder: "Hello", projectID: home.project.id, displayName: "Clock", buildSystem: "apelin", isThisProject: true),
            ListedProject(folder: "Weather", projectID: Self.weather.id, displayName: "Rain Radar", buildSystem: "external", isThisProject: false),
        ], truncated: false))
        let runner = try Self.runner(home, store, backend)

        let listing = try await JSONDecoder().decode(Listing.self, from: Data(Self.run(runner, .memoryList, ["all_projects": true]).utf8))
        #expect(listing.revision == snapshot.revision)
        #expect(listing.records == [
            .init(title: "Language"),
            .init(title: "Target", projectID: home.project.id, folder: "Hello", displayName: "Clock"),
            .init(title: "Units", projectID: Self.weather.id, folder: "Weather", displayName: "Rain Radar"),
            .init(title: "Old", projectID: "gone-project", missing: true),
        ])
        await #expect(throws: ToolArgumentError.self, "one project or every project, not both") {
            try await Self.run(runner, .memoryList, ["all_projects": true, "project": "Weather"])
        }

        // A list cut short is no proof that a project is gone.
        await backend.setListedProjects(ProjectListToolResponse(projects: [], truncated: true))
        await backend.addProject(home.project)
        await backend.addProject(Self.weather)
        let cut = try await JSONDecoder().decode(Listing.self, from: Data(Self.run(runner, .memoryList, ["all_projects": true]).utf8))
        #expect(cut.records.map(\.missing) == [nil, nil, nil, true])
        #expect(cut.records.map(\.folder) == [nil, "Hello", "Weather", nil])

        // The gone project's records are reached by its projectID, to
        // change or delete, but it takes no new one.
        let refused = await #expect(throws: ToolArgumentError.self) {
            try await Self.run(runner, .memorySave, ["revision": .string(snapshot.revision), "title": "More", "body": "Nothing.", "project": "gone-project"])
        }
        #expect(refused?.message.contains("not added to") == true)
        _ = try await Self.run(runner, .memoryDelete, ["revision": .string(snapshot.revision), "id": .string(old.id), "project": "gone-project"])
        #expect(try store.read().records.map(\.title) == ["Language", "Target", "Units"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `General Chat keeps a project record only for the project it names, never for its own temporary id`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        let backend = MockBackend()
        await backend.addProject(Self.weather)
        let id = UUID().uuidString
        let runner = try Self.runner(home, store, backend, project: ProjectIdentity(id: "temporary:" + id, name: ProjectName(id)))
        for scope: KWWKAI.JSONValue in [.null, "project"] {
            let error = await #expect(throws: ToolArgumentError.self) {
                try await Self.run(runner, .memorySave, ["revision": .string(store.read().revision), "title": "Units", "body": "Celsius.", "scope": scope])
            }
            #expect(error?.message.contains("General Chat has no project of its own") == true)
        }
        #expect(try store.read().records.isEmpty)
        _ = try await Self.run(runner, .memorySave, ["revision": .string(store.read().revision), "title": "Language", "body": "Use Chinese.", "scope": "global"])
        _ = try await Self.run(runner, .memorySave, ["revision": .string(store.read().revision), "title": "Units", "body": "Celsius.", "project": "Weather"])
        #expect(try store.read().records.map(\.projectID) == [nil, Self.weather.id])
    }
}
