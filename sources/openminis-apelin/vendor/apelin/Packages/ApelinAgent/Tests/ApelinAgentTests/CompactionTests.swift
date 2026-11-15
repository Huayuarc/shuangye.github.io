@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Compaction the app asks for")
struct CompactionTests {
    @Test(.timeLimit(.minutes(1)))
    func `a long conversation is compacted, saved, and the next message runs on the summary`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        // three replies of about 10k tokens each: more than the 20k kwwk keeps as they are
        let long = String(repeating: "The build log says the hook loaded. ", count: 1200)
        faux.setResponses([
            .message(fauxAssistantMessage("First: " + long)),
            .message(fauxAssistantMessage("Second: " + long)),
            .message(fauxAssistantMessage("Third: " + long)),
            .message(fauxAssistantMessage("The user built a tweak; the hook loads.")),
            .message(fauxAssistantMessage("Carrying on from the summary.")),
        ])
        let session = try await openSession(home, faux: faux)
        let stream = try await session.events(afterSeq: 0)
        var events = stream.makeAsyncIterator()
        for prompt in ["one", "two", "three"] {
            try await session.prompt(prompt)
            await session.waitForIdle()
        }
        let before = try await session.log.readTranscript().count

        try await session.compact()
        let result = try #require(await Self.compaction(from: &events))
        #expect(result.outcome == .compacted, "\(result)")
        #expect((result.messagesCompacted ?? 0) > 0)
        #expect(try await session.log.readTranscript().count < before)
        // the summary the conversation goes on from, without the recap's markup
        #expect(result.summary == "The user built a tweak; the hook loads.")
        // and in the log, which a reopened session replays
        let logged = try await session.log.records(afterSeq: 0).compactMap { record -> AgentCompactionResult? in
            guard case let .compactionFinished(result) = record.event else { return nil }
            return result
        }
        #expect(logged == [result])

        try await session.prompt("four")
        await session.waitForIdle()
        let last = try await session.log.readTranscript().last
        guard case let .assistant(reply)? = last else {
            Issue.record("no reply after compacting: \(String(describing: last))")
            return
        }
        #expect(reply.content == [fauxText("Carrying on from the summary.")])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a short conversation is left as it is`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("Hello."))])
        let session = try await openSession(home, faux: faux)
        let stream = try await session.events(afterSeq: 0)
        var events = stream.makeAsyncIterator()
        try await session.prompt("hi")
        await session.waitForIdle()
        let before = try await session.log.readTranscript()

        try await session.compact()
        let result = try #require(await Self.compaction(from: &events))
        // nothing compacted, so no summary either
        #expect(result == AgentCompactionResult(outcome: .tooShort))
        #expect(try await session.log.readTranscript() == before)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a run in progress refuses it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(
                    name: "apelin_package_remove",
                    arguments: ["reason": "Remove it", "installation_id": "inst-1"],
                )],
                stopReason: .toolUse,
            )),
            .message(fauxAssistantMessage("never reached")),
        ])
        let session = try await openSession(home, faux: faux)
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("remove it")
        for await record in stream {
            guard case .approvalRequested = record.event else { continue }
            await #expect(throws: ApelinError.self) { try await session.compact() }
            await session.abort()
            break
        }
        await session.close()
    }

    private func openSession(_ home: TemporaryHome, faux: FauxProviderRegistration) async throws -> AgentSession {
        try await AgentSession(
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
    }

    /// The outcome the next `compactionFinished` reports, after its start.
    private static func compaction(
        from events: inout AsyncStream<SessionEventRecord>.Iterator,
    ) async -> AgentCompactionResult? {
        var started = false
        while let record = await events.next() {
            switch record.event {
            case .compactionStarted:
                started = true
            case let .compactionFinished(result) where started:
                return result
            default:
                continue
            }
        }
        return nil
    }
}
