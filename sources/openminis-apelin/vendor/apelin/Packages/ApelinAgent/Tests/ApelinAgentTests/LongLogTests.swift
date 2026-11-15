@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

/// A conversation of 684,540 lines once took 104 s to open on a device,
/// past the 30 s the app gives `agentOpen`: the open decoded its log four
/// times, the last inside the log's actor, where the next message waited.
@Suite("A long event log")
struct LongLogTests {
    @Test(.timeLimit(.minutes(1)))
    func `opening decodes only the lines it needs, and the replay each line once, in order`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let sessionID = UUID().uuidString
        let first = UUID()
        let second = UUID()
        let answered = Self.approval("answered")
        let abandoned = Self.approval("abandoned")
        let needed: [Int: AgentSessionEvent] = [
            1: .userMessage(id: first, text: "Write a long essay.", attachments: []),
            900: .titleUpdated("A long essay"),
            20000: .approvalRequested(answered),
            20010: .approvalResolved(requestID: answered.id, decision: .approve(.once)),
            35000: .userMessage(id: second, text: "Go on.", attachments: []),
            45000: .approvalRequested(abandoned),
        ]
        // The open's bound does not grow with the log, while a debug
        // build's replay pays some 14 µs a line: this many keep it quick.
        let lines = 50000
        var file = try SyntheticLog(home: home, sessionID: sessionID)
        for seq in 1 ... lines {
            try file.append(needed[seq] ?? Self.streamed(seq))
        }
        try file.write()
        let configuration = AgentSessionConfiguration(
            id: sessionID,
            project: home.project,
            provider: .registered(faux.getModel()),
            approval: ApprovalPolicy(mode: .confirm),
            dataRoot: home.dataRoot,
        )
        func open() async throws -> AgentSession {
            try await AgentSession(
                configuration: configuration,
                backend: MockBackend(),
                digests: MockDigestLedger(),
                credentials: DeliveredCredentialSource(),
            )
        }

        let session = try await open()
        let opening = await session.log.decodes
        #expect(opening <= needed.count + 1, "the lines the summary reads, and the last for its number")
        // the session took the summary: a message it has is a duplicate
        let seq = await session.log.lastSeq
        #expect(seq == UInt64(lines) + 1, "the abandoned approval is closed")
        try await session.prompt("Go on.", messageID: second)
        #expect(await session.log.lastSeq == seq)

        let stream = try await session.events(afterSeq: 0)
        try await session.log.append(.notice(title: nil, body: "after the attach"))
        var replayed: [SessionEventRecord] = []
        for await record in stream {
            replayed.append(record)
            if case .notice = record.event {
                break
            }
        }
        #expect(replayed.map(\.seq) == Array(1 ... seq + 1))
        #expect(await session.log.decodes == opening + Int(seq), "each line the replay read, once")
        #expect(await session.log.opened == SessionEventLog.Summary(Array(replayed.prefix(lines))))
        #expect(await session.log.opened.userMessageIDs == [first, second])
        #expect(await session.log.opened.openApprovals == [abandoned.id])
        let closings = replayed.filter {
            $0.event == .approvalResolved(requestID: abandoned.id, decision: .deny(reason: "the session restarted"))
        }
        #expect(closings.map(\.seq) == [UInt64(lines) + 1])
        await session.close()

        // Opened again, it has nothing left to close.
        let reopened = try await open()
        #expect(await reopened.log.decodes <= needed.count + 2)
        #expect(await reopened.log.opened.openApprovals.isEmpty)
        #expect(await reopened.log.lastSeq == seq + 1)
        await reopened.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `an append does not wait for a replay, and follows it with no gap or duplicate`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sessionID = UUID().uuidString
        var file = try SyntheticLog(home: home, sessionID: sessionID)
        // a few of the replay's chunks
        let lines = 30000
        for seq in 1 ... lines {
            try file.append(Self.streamed(seq))
        }
        try file.write()
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        let gate = ReplayGate()
        let stream = try await log.attach(afterSeq: 0, pausing: { await gate.pause() })
        await gate.waitUntilPaused()
        // the replay holds after its first chunk until the gate opens
        try await log.append(.notice(title: nil, body: "written meanwhile"))
        #expect(await log.lastSeq == UInt64(lines) + 1)
        #expect(await gate.pauses == 1)
        await gate.open()
        var seqs: [UInt64] = []
        var last: AgentSessionEvent?
        for await record in stream {
            seqs.append(record.seq)
            if record.seq == UInt64(lines) + 1 {
                last = record.event
                break
            }
        }
        #expect(seqs == Array(1 ... UInt64(lines) + 1))
        #expect(last == .notice(title: nil, body: "written meanwhile"))
        #expect(await gate.pauses > 1, "it read more than one chunk")
        await log.close()
    }

    @Test
    func `a damaged line the open reads past stands as an error in the replay, which goes on`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sessionID = UUID().uuidString
        var file = try SyntheticLog(home: home, sessionID: sessionID)
        try file.append(.userMessage(id: UUID(), text: "Hello", attachments: []))
        try file.append(.thinkingDelta("a"))
        // a delta's line with its text cut open: its kind still reads
        file.appendRaw(#"{"date":"2027-01-15T08:00:00Z","event":{"thinkingDelta":{"_0":"brok},"seq":3}"#)
        try file.append(.thinkingDelta("b"))
        try file.write()

        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        #expect(await log.lastSeq == 4)
        let stream = try await log.attach(afterSeq: 0)
        try await log.append(.finished(reason: .completed))
        var replayed: [SessionEventRecord] = []
        for await record in stream {
            replayed.append(record)
            if record.seq == 5 {
                break
            }
        }
        #expect(replayed.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(replayed[2].event == .error(message: "Part of this chat's history could not be read."))
        #expect(replayed[3].event == .thinkingDelta("b"))
        // the strict read still calls it damaged
        await #expect(throws: SessionStoreError.corrupt("line 3")) {
            _ = try await log.records(afterSeq: 0)
        }
        await log.close()
    }

    @Test
    func `a line laid out another way is decoded, and a damaged one the summary needs stops the open`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let message = UUID()
        var unsorted = try SyntheticLog(home: home, sessionID: UUID().uuidString)
        // valid, with its keys in another order: its kind cannot be read
        unsorted.appendRaw(
            #"{"seq":1,"event":{"userMessage":{"id":"\#(message.uuidString)","text":"Hi","attachments":[]}},"date":"2027-01-15T08:00:00Z"}"#,
        )
        try unsorted.append(.thinkingDelta("a"))
        try unsorted.write()
        let opened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: unsorted.sessionID)
        #expect(await opened.opened.userMessageIDs == [message])
        #expect(await opened.decodes == 2, "that line and the last")
        await opened.close()

        var damaged = try SyntheticLog(home: home, sessionID: UUID().uuidString)
        try damaged.append(.thinkingDelta("a"))
        damaged.appendRaw(#"{"date":"2027-01-15T08:00:00Z","event":{"userMessage":{"id":"not an id"}},"seq":2}"#)
        try damaged.append(.thinkingDelta("b"))
        try damaged.write()
        #expect(throws: SessionStoreError.corrupt("line 2")) {
            _ = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: damaged.sessionID)
        }

        // A whole last line that will not decode is torn, as one cut short is.
        var torn = try SyntheticLog(home: home, sessionID: UUID().uuidString)
        try torn.append(.thinkingDelta("a"))
        torn.appendRaw(#"{"date":"2027-01-15T08:00:00Z","event":{"textDelta":{"_0":"b"#)
        try torn.write()
        let cut = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: torn.sessionID)
        #expect(await cut.lastSeq == 1)
        try await cut.append(.finished(reason: .completed))
        #expect(try await cut.records(afterSeq: 0).map(\.event) == [.thinkingDelta("a"), .finished(reason: .completed)])
        await cut.close()
    }

    @Test
    func `the kinds the summary reads are spelled as the encoder writes them`() throws {
        let needed: [AgentSessionEvent] = [
            .userMessage(id: UUID(), text: "Hi", attachments: []),
            .titleUpdated("A title"),
            .approvalRequested(Self.approval("asked")),
            .approvalResolved(requestID: "asked", decision: .deny(reason: "no")),
        ]
        let others: [AgentSessionEvent] = [
            .thinkingDelta("a"), .textDelta("b"), .received(tokens: 3), .messageStarted,
            .userMessageQueued(id: UUID(), text: "Hi", attachments: []), .finished(reason: .completed),
        ]
        func kind(_ event: AgentSessionEvent) throws -> String? {
            let line = try SyntheticLog.encoder.encode(SessionEventRecord(seq: 7, date: Date(), event: event))
            return line.withUnsafeBytes { SessionEventLog.kind(of: $0) }
        }
        let names = try needed.map(kind)
        #expect(Set(names.compactMap(\.self)) == SessionEventLog.Summary.kinds && !names.contains(nil))
        for event in others {
            let name = try kind(event)
            #expect(name.map { !SessionEventLog.Summary.kinds.contains($0) } == true)
        }
        #expect(try kind(.thinkingDelta("x")) == "thinkingDelta")
    }

    // MARK: - Helpers

    /// A conversation's streamed bulk, a thousand lines at a time much as
    /// the long one was: mostly thinking, some text, a count now and then.
    static func streamed(_ seq: Int) -> AgentSessionEvent {
        switch seq % 1000 {
        case 2: .messageStarted
        case 999: .messageFinished(text: "Done.")
        case let position where position % 100 == 50: .received(tokens: seq)
        case 950 ..< 999: .textDelta("word ")
        default: .thinkingDelta("hmm, ")
        }
    }

    static func approval(_ id: String) -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            toolCallID: "call-\(id)",
            tool: "apelin_package_remove",
            arguments: "{}",
            workingDirectory: "/",
            projectID: "project",
            fingerprint: id,
            reason: "Remove it",
            detail: .none,
            allowsSessionScope: false,
        )
    }
}

/// `events.jsonl` written straight to disk as the log's encoder lays it
/// out, and fast: each distinct event is encoded once, its number spliced
/// onto the end of its line.
private struct SyntheticLog {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    let sessionID: String
    let url: URL
    private var data = Data()
    private var lines = 0
    private var templates: [AgentSessionEvent: Data] = [:]
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    init(home: TemporaryHome, sessionID: String) throws {
        self.sessionID = sessionID
        let directory = home.dataRoot.sessions.appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("events.jsonl")
    }

    /// `event` as the next line, numbered as the log numbers it.
    mutating func append(_ event: AgentSessionEvent) throws {
        lines += 1
        if templates[event] == nil {
            let line = try Self.encoder.encode(SessionEventRecord(seq: 0, date: date, event: event))
            // the encoder sorts keys, so every line ends with its number
            let end = Data(#""seq":0}"#.utf8)
            guard line.suffix(end.count) == end else { throw SessionStoreError.corrupt("an unexpected layout") }
            templates[event] = line.prefix(line.count - 2)
        }
        data.append(templates[event]!)
        data.append(contentsOf: "\(lines)}\n".utf8)
    }

    /// A line exactly as given, counted as the next one.
    mutating func appendRaw(_ line: String) {
        lines += 1
        data.append(contentsOf: line.utf8)
        data.append(0x0A)
    }

    func write() throws {
        try data.write(to: url)
    }
}

/// Holds a replay after its first chunk until the test opens it.
private actor ReplayGate {
    private(set) var pauses = 0
    private var isOpen = false
    private var held: CheckedContinuation<Void, Never>?
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        pauses += 1
        for watcher in watchers {
            watcher.resume()
        }
        watchers = []
        guard !isOpen else { return }
        await withCheckedContinuation { held = $0 }
    }

    func waitUntilPaused() async {
        guard pauses == 0 else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        isOpen = true
        held?.resume()
        held = nil
    }
}
