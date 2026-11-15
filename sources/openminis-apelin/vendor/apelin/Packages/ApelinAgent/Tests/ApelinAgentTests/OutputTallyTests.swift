@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("What a run has received, for the app's counter")
struct OutputTallyTests {
    @Test
    func `streamed output is estimated and recorded at most every quarter second`() {
        var tally = OutputTally()
        let start = Date(timeIntervalSince1970: 100)
        tally.startMessage()
        tally.add("abcd") // one token
        #expect(tally.take(at: start) == 1)
        tally.add("efgh")
        #expect(tally.take(at: start.addingTimeInterval(0.1)) == nil, "too soon after the last")
        #expect(tally.take(at: start.addingTimeInterval(0.25)) == 2)
        #expect(tally.take(at: start.addingTimeInterval(1)) == nil, "nothing new")
        tally.add("你好")
        #expect(tally.take(at: start.addingTimeInterval(1.1)) == 4, "a token to each character that is not ASCII")
    }

    @Test
    func `an ended message counts at the provider's figure, or its estimate without one`() {
        var tally = OutputTally()
        let now = Date(timeIntervalSince1970: 100)
        tally.startMessage()
        tally.add(String(repeating: "a", count: 40)) // ten tokens estimated
        tally.endMessage(reported: 37)
        #expect(tally.take(at: now, messageEnded: true) == 37)
        tally.startMessage()
        tally.add(String(repeating: "b", count: 8))
        tally.endMessage(reported: 0)
        #expect(tally.take(at: now.addingTimeInterval(0.01), messageEnded: true) == 39, "an end is recorded at once")
        tally.startMessage()
        tally.add(String(repeating: "c", count: 400))
        tally.startMessage() // a retry: the abandoned attempt never ended
        #expect(tally.total == 39)
    }

    @Test
    func `nothing is recorded before anything streams`() {
        var tally = OutputTally()
        #expect(tally.take(at: Date(), messageEnded: true) == nil)
    }

    /// A run records its total before each message's end, at the provider's
    /// count, growing through the run; the next run counts from nothing.
    @Test(.timeLimit(.minutes(1)))
    func `a session records each run's output, ending on the provider's count`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("README.md", "Hello\n")
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [
                fauxThinking("Read the readme first."),
                fauxText("Reading it."),
                fauxToolCall(name: "file_read", arguments: ["reason": "Read the readme", "path": "README.md"]),
            ], stopReason: .toolUse)),
            .message(fauxAssistantMessage("It says hello.")),
            .message(fauxAssistantMessage("Still hello.")),
        ])
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

        func run(_ prompt: String, after seq: UInt64) async throws -> [AgentSessionEvent] {
            let stream = try await session.events(afterSeq: seq)
            try await session.prompt(prompt)
            var events: [AgentSessionEvent] = []
            for await record in stream {
                events.append(record.event)
                if case .finished = record.event {
                    break
                }
            }
            await session.waitForIdle()
            return events
        }

        func counts(_ events: [AgentSessionEvent]) -> [Int] {
            events.compactMap { event in
                if case let .received(tokens) = event {
                    return tokens
                }
                return nil
            }
        }

        func reported(_ messages: [Message]) -> [Int] {
            messages.compactMap { message in
                if case let .assistant(assistant) = message {
                    return assistant.usage.output
                }
                return nil
            }
        }

        let first = try await run("What does the readme say?", after: 0)
        let firstReported = try await reported(session.log.readTranscript())
        #expect(firstReported.count == 2 && firstReported.allSatisfy { $0 > 0 })
        let firstCounts = counts(first)
        #expect(firstCounts == firstCounts.sorted() && Set(firstCounts).count == firstCounts.count, "it only grows")
        #expect(firstCounts.last == firstReported.reduce(0, +), "the run ends on the provider's count")
        let firstEnd = try #require(first.firstIndex {
            if case .messageFinished = $0 {
                true
            } else {
                false
            }
        })
        #expect(counts(Array(first[..<firstEnd])).last == firstReported.first, "a message's count is in before its end")

        let seq = await session.log.lastSeq
        let second = try await run("And now?", after: seq)
        let secondReported = try await reported(session.log.readTranscript())
        #expect(counts(second).last == secondReported.last, "a new run counts from nothing")
        await session.close()
    }
}
