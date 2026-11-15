@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// A provider streams a delta every few characters; the log writes them a
/// few hundred bytes at a time. A long conversation once wrote 643,566
/// thinking lines, one a delta, and took minutes to open again.
@Suite("Streamed text in the event log")
struct EventCoalescingTests {
    @Test
    func `a pending delta is written before any other event, whoever appends it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        try await log.append(.thinkingDelta("Let me "))
        try await log.append(.thinkingDelta("look."))
        #expect(await log.lastSeq == 0, "streamed text waits for its record")
        // the approval gate and the tool runner append to the log directly
        try await log.append(.toolCallPreparing)
        #expect(await log.lastSeq == 2)
        try await log.append(.textDelta("Here"))
        try await log.append(.textDelta(" it is."))
        // the other stream starts a record of its own
        try await log.append(.thinkingDelta("And"))
        await log.close()

        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        let records = try await reopened.records(afterSeq: 0)
        #expect(records.map(\.seq) == [1, 2, 3, 4])
        #expect(records.map(\.event) == [
            .thinkingDelta("Let me look."),
            .toolCallPreparing,
            .textDelta("Here it is."),
            .thinkingDelta("And"),
        ])
        await reopened.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a record is written once it holds 512 bytes of UTF-8, and a lone delta at its deadline`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        let stream = try await log.attach(afterSeq: 0)
        // six bytes a delta: 85 hold 510, the 86th takes the record past 512
        for _ in 1 ... 85 {
            try await log.append(.thinkingDelta("思考"))
        }
        #expect(await log.lastSeq == 0)
        try await log.append(.thinkingDelta("思考"))
        #expect(await log.lastSeq == 1)
        // nothing follows this one: its deadline writes it
        try await log.append(.thinkingDelta("尾"))
        var received: [SessionEventRecord] = []
        for await record in stream {
            received.append(record)
            if received.count == 2 {
                break
            }
        }
        #expect(received.map(\.event) == [
            .thinkingDelta(String(repeating: "思考", count: 86)),
            .thinkingDelta("尾"),
        ])
        #expect(received.map(\.seq) == [1, 2])
        await log.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a long streamed reply is written in a few records, its text whole and in order`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        // four characters a delta, the finest the faux provider streams
        let faux = await registerFauxProvider(RegisterFauxProviderOptions(tokenSize: FauxTokenSize(min: 1, max: 1)))
        defer { faux.unregister() }
        let thinking = String(repeating: "Weigh this. ", count: 1667) // 20,004 characters
        let text = String(repeating: "答案在这里。 ", count: 715) // 5,005 characters, 13,585 bytes
        faux.setResponses([.message(fauxAssistantMessage(blocks: [fauxThinking(thinking), fauxText(text)]))])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        let clock = ContinuousClock()
        let started = clock.now
        try await session.prompt("Explain it at length.")
        for await record in stream {
            if case .finished = record.event {
                break
            }
        }
        let streamed = clock.now - started
        await session.waitForIdle()
        let records = try await session.log.records(afterSeq: 0)
        await session.close()

        func streamText(_ thinking: Bool) -> [String] {
            records.compactMap { record in
                switch record.event {
                case let .thinkingDelta(delta) where thinking: delta
                case let .textDelta(delta) where !thinking: delta
                default: nil
                }
            }
        }
        #expect(streamText(true).joined() == thinking)
        #expect(streamText(false).joined() == text)
        let events = records.map(\.event)
        let isDelta: (AgentSessionEvent) -> Bool = {
            switch $0 {
            case .textDelta, .thinkingDelta: true
            default: false
            }
        }
        let firstDelta = try #require(events.firstIndex(where: isDelta))
        let lastDelta = try #require(events.lastIndex(where: isDelta))
        let lastThinking = try #require(events.lastIndex {
            if case .thinkingDelta = $0 {
                return true
            }
            return false
        })
        let firstText = try #require(events.firstIndex {
            if case .textDelta = $0 {
                return true
            }
            return false
        })
        #expect(events.firstIndex(of: .messageStarted).map { $0 < firstDelta } == true)
        #expect(lastThinking < firstText, "the thinking, then the text")
        #expect(events.firstIndex(of: .messageFinished(text: text)).map { $0 > lastDelta } == true)
        #expect(records.map(\.seq) == Array(1 ... UInt64(records.count)))

        // A record falls short of 512 bytes only where the other stream
        // starts, where another event comes (here a `received` count), at
        // its 250 ms deadline (at most once a quarter second of streaming),
        // and at each stream's end.
        let deltaRecords = events.count(where: isDelta)
        let counts = events.count {
            if case .received = $0 {
                return true
            }
            return false
        }
        let deadlines = Int(streamed / SessionEventLog.recordDeadline) + 1
        let bound = thinking.utf8.count / 512 + text.utf8.count / 512 + 2 + 1 + counts + deadlines
        #expect(deltaRecords <= bound)
        // the provider streamed 6,253 deltas
        let deltas = (thinking.count + 3) / 4 + (text.count + 3) / 4
        #expect(deltaRecords * 20 < deltas, "\(deltaRecords) records for \(deltas) deltas")
    }
}
