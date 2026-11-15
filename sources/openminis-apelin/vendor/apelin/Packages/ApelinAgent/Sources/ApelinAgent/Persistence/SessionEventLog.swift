import Foundation
import KWWKAI

public enum SessionStoreError: Error, Equatable, LocalizedError {
    case invalidSessionID(String)
    case corrupt(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSessionID(id): "'\(id)' is not a session id"
        case let .corrupt(detail): "session record is damaged: \(detail)"
        case let .io(detail): detail
        }
    }
}

/// What a session directory remembers besides its events. No credential is
/// ever part of it: the provider is named, the key lives in the
/// `CredentialSource`.
public struct SessionMetadata: Sendable, Hashable, Codable {
    public var id: String
    public var project: ProjectIdentity
    public var provider: ProviderConfiguration
    public var mode: ApprovalMode
    public var created: Date

    public init(
        id: String,
        project: ProjectIdentity,
        provider: ProviderConfiguration,
        mode: ApprovalMode,
        created: Date,
    ) {
        self.id = id
        self.project = project
        self.provider = provider
        self.mode = mode
        self.created = created
    }
}

/// `~/Documents/wiki.qaq.apelin/sessions/<id>/`: `session.json`,
/// `events.jsonl` (one `SessionEventRecord` per line, sequence numbers from
/// 1, appended before delivery) and `transcript.json` (the model
/// conversation, rewritten at the end of every run so a restarted
/// `apelin-agent` resumes it).
///
/// Streamed text is coalesced before it is written: a `textDelta` or
/// `thinkingDelta` joins the pending record of its kind, which is written
/// once it holds 512 bytes, 250 ms after its first delta, before any other
/// event, and on `close()`. Its record is the same event with longer text,
/// so the text, its order and every message's bounds are what they were,
/// and an older build reads the log as it always has. A process killed
/// mid-stream loses at most that pending record — under 512 bytes, under
/// 250 ms of streamed text —, never any other event: those are on disk
/// before `append` returns.
///
/// The event log is the only thing an app reattaches to: `attach(afterSeq:)`
/// replays from disk and continues live, with no gap and no duplicate, in
/// the file's order. The replay reads the file outside this actor, up to
/// where it ended at the attach; what is written from then on is held for
/// that subscriber and follows once the replay has read the rest, so an
/// append never waits for a replay.
public actor SessionEventLog {
    public let directory: URL
    /// What the log held when it was opened, read in the pass that found
    /// its end: what a session needs to carry on, so nothing reads the log
    /// again for it.
    let opened: Summary
    private let events: URL
    private var nextSeq: UInt64
    /// The bytes the whole lines take up: where the next one goes.
    private var length: UInt64
    private var handle: FileHandle?
    private var pending: PendingDelta?
    /// Writes the pending delta when its 250 ms are up.
    private var deadline: Task<Void, Never>?
    private var subscribers: [UUID: Subscriber] = [:]
    /// Lines decoded in full: by the opening scan, which decodes only the
    /// few `opened` needs, by every replay and by `records(afterSeq:)`.
    /// What a test holds an open to.
    private(set) var decodes: Int
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A pending delta is written once it holds this many bytes of UTF-8…
    static let recordBytes = 512
    /// …or this long after its first delta.
    static let recordDeadline: Duration = .milliseconds(250)

    /// Streamed text not written yet: one kind's deltas, joined.
    private struct PendingDelta {
        var thinking: Bool
        var text: String
        /// When its first delta came: the record's date.
        var date: Date

        var event: AgentSessionEvent {
            thinking ? .thinkingDelta(text) : .textDelta(text)
        }
    }

    private final class Subscriber {
        let continuation: AsyncStream<SessionEventRecord>.Continuation
        /// While its replay reads the file: the records written since the
        /// attach, yielded once the replay has read the rest.
        var held: [SessionEventRecord]?
        var replay: Task<Void, Never>?

        init(_ continuation: AsyncStream<SessionEventRecord>.Continuation) {
            self.continuation = continuation
        }
    }

    /// Opens (creating if needed) the directory for `sessionID` under
    /// `sessionsRoot`, continuing the sequence after the last valid line.
    public init(sessionsRoot: URL, sessionID: String) throws {
        guard Self.isValidSessionID(sessionID) else { throw SessionStoreError.invalidSessionID(sessionID) }
        let directory = sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
        try Self.makeDirectory(sessionsRoot)
        try Self.makeDirectory(directory)
        let events = directory.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: events.path) {
            guard FileManager.default.createFile(atPath: events.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw SessionStoreError.io("could not create \(events.lastPathComponent)")
            }
        }
        let scan = try Self.scan(events)
        let handle = try FileHandle(forWritingTo: events)
        if scan.length < scan.size {
            // Drop a torn last line so the next record starts on its own line.
            try handle.truncate(atOffset: UInt64(scan.length))
        }
        _ = try handle.seekToEnd()
        self.directory = directory
        self.events = events
        self.handle = handle
        opened = scan.summary
        nextSeq = scan.summary.lastSeq + 1
        length = UInt64(scan.length)
        decodes = scan.decodes
    }

    /// Session ids are UUIDs, so one can never name a path.
    public static func isValidSessionID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// The last record written. A pending delta has no number until it is.
    public var lastSeq: UInt64 {
        nextSeq - 1
    }

    /// Writes the event, the pending delta first, then delivers it. A
    /// `textDelta` or `thinkingDelta` joins the pending record instead,
    /// written as the type's comment says. After `close()` nothing is.
    public func append(_ event: AgentSessionEvent) throws {
        guard handle != nil else { return }
        switch event {
        case let .textDelta(text):
            try join(text, thinking: false)
        case let .thinkingDelta(text):
            try join(text, thinking: true)
        default:
            try flush()
            try write(event, date: Date())
        }
    }

    /// Every record after `afterSeq` from disk, then live ones. It returns
    /// at once; the records already written are read outside this actor.
    public func attach(afterSeq: UInt64) throws -> AsyncStream<SessionEventRecord> {
        try attach(afterSeq: afterSeq, pausing: nil)
    }

    /// `pause`: awaited by the replay after each chunk it has yielded, so a
    /// test can append while one is under way; nil in the worker.
    func attach(
        afterSeq: UInt64,
        pausing pause: (@Sendable () async -> Void)?,
    ) throws -> AsyncStream<SessionEventRecord> {
        guard handle != nil else { throw SessionStoreError.io("the session's event log is closed") }
        let (stream, continuation) = AsyncStream<SessionEventRecord>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let subscriber = Subscriber(continuation)
        subscribers[id] = subscriber
        continuation.onTermination = { [weak self] _ in
            Task { await self?.detach(id) }
        }
        if afterSeq < lastSeq {
            // Everything written so far lies before `length`; what is
            // written from now on is held until the replay has read that.
            subscriber.held = []
            let (events, length, lastSeq) = (events, length, lastSeq)
            subscriber.replay = Task.detached {
                let decodes = await Self.replay(
                    events,
                    length: length,
                    afterSeq: afterSeq,
                    lastSeq: lastSeq,
                    to: continuation,
                    pausing: pause,
                )
                await self.replayEnded(id, decodes: decodes)
            }
        }
        return stream
    }

    /// Every record after `afterSeq`, read at once with the pending delta
    /// written first: for tests and small logs. A damaged line anywhere but
    /// last is an error here.
    public func records(afterSeq: UInt64) throws -> [SessionEventRecord] {
        try flush()
        let read = try Self.readRecords(events)
        decodes += read.decodes
        return read.records.filter { $0.seq > afterSeq }
    }

    /// Writes the pending delta, ends every subscriber's stream and closes
    /// the file.
    public func close() {
        try? flush()
        for subscriber in subscribers.values {
            subscriber.replay?.cancel()
            subscriber.continuation.finish()
        }
        subscribers.removeAll()
        try? handle?.close()
        handle = nil
    }

    private func detach(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.replay?.cancel()
    }

    /// The replay has yielded what the file held at the attach: the records
    /// written since follow, and the subscriber is live.
    private func replayEnded(_ id: UUID, decodes: Int) {
        self.decodes += decodes
        guard let subscriber = subscribers[id] else { return }
        for record in subscriber.held ?? [] {
            subscriber.continuation.yield(record)
        }
        subscriber.held = nil
        subscriber.replay = nil
    }

    // MARK: - Writing

    private func join(_ text: String, thinking: Bool) throws {
        if pending?.thinking == !thinking {
            try flush()
        }
        if pending == nil {
            pending = PendingDelta(thinking: thinking, text: "", date: Date())
        }
        pending?.text += text
        if (pending?.text.utf8.count ?? 0) >= Self.recordBytes {
            try flush()
        } else if deadline == nil {
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: Self.recordDeadline) } catch { return }
                await self?.deadlinePassed()
            }
        }
    }

    /// A pending delta's 250 ms are up. A write that fails here is tried
    /// again by the next append, which reports it.
    private func deadlinePassed() {
        // a flush that came first cancelled this deadline
        guard !Task.isCancelled else { return }
        try? flush()
    }

    /// Writes the pending delta, if there is one.
    private func flush() throws {
        deadline?.cancel()
        deadline = nil
        guard let pending else { return }
        try write(pending.event, date: pending.date)
        self.pending = nil
    }

    private func write(_ event: AgentSessionEvent, date: Date) throws {
        guard let handle else { return }
        let record = SessionEventRecord(seq: nextSeq, date: date, event: event)
        var line = try encoder.encode(record)
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
        } catch {
            // A line written in part would run into the next one.
            try? handle.truncate(atOffset: length)
            throw error
        }
        length += UInt64(line.count)
        nextSeq += 1
        for subscriber in subscribers.values {
            if subscriber.held == nil {
                subscriber.continuation.yield(record)
            } else {
                subscriber.held?.append(record)
            }
        }
    }

    // MARK: - Metadata and transcript

    public func writeMetadata(_ metadata: SessionMetadata) throws {
        try writeAtomically(encoder.encode(metadata), name: "session.json")
    }

    public func readMetadata() throws -> SessionMetadata? {
        let url = directory.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(SessionMetadata.self, from: Data(contentsOf: url))
    }

    public func writeTranscript(_ messages: [Message]) throws {
        try writeAtomically(encoder.encode(messages), name: "transcript.json")
    }

    public func readTranscript() throws -> [Message] {
        let url = directory.appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.decoder.decode([Message].self, from: Data(contentsOf: url))
    }

    private func writeAtomically(_ data: Data, name: String) throws {
        let url = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SessionStoreError.io("could not write \(name)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw SessionStoreError.io("could not replace \(name)")
        }
    }

    // MARK: - Helpers

    private static func makeDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw SessionStoreError.io("\(url.lastPathComponent) is not a folder") }
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
    }
}
