import ApelinCore
import ApelinProtocol
import Foundation

/// Every task the session host owns: its record, its numbered events, and
/// the attaches waiting for the next one. Events are written to
/// `<state>/tasks/` as they come and the record whenever it changes in a
/// way the events do not tell (`append`), so both are on disk before the
/// host reports idle and exits; the next launch reads them back. `load` hands
/// back the tasks that were still running: the host offers each to the
/// resumer registered for its kind (an install follows its irisind
/// transaction again from `resume`; a build or environment task is started
/// again by `TaskResume`), and marks the rest `interrupted`.
actor TaskRegistry {
    struct Record: Codable {
        var id: TaskID
        var kind: TaskKind
        var state: TaskState
        var createdAt: Date
        var updatedAt: Date
        var lastSeq: EventSeq
        /// The worker serving it, by role and instance key.
        var owner: WorkerRole?
        var ownerKey: String?
        var cancelRequested: Bool
        /// What the owning domain needs to pick the task up after a restart
        /// (an install's installation ID, a `TaskResume.Plan`). Nil: it
        /// cannot be resumed.
        var resume: JSONValue?
    }

    static let maximumWaitMilliseconds = 60000

    private let directory: URL
    private var records: [TaskID: Record] = [:]
    private var events: [TaskID: [TaskEvent]] = [:]
    private var waiters: [TaskID: [UUID: CheckedContinuation<Void, Never>]] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// Reads the records left on disk and answers the unfinished ones, which
    /// the caller resumes or marks `interrupted`.
    @discardableResult
    func load() -> [Record] {
        var unfinished: [Record] = []
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        let decoder = JSONCoding.decoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var record = try? decoder.decode(Record.self, from: data)
            else {
                continue
            }
            var (replay, trailing) = readEvents(record.id)
            // The record is not written again for an ordinary event
            // (`append`), so its time is the last event's that read, and
            // only forward.
            if let last = replay.last, last.time > record.updatedAt {
                record.updatedAt = last.time
            }
            // A record already final whose final `state` line no longer
            // reads would replay with no end: an attach reports it finished
            // with no `state` to take the result from. The lines past the
            // last that read keep their numbers as `unreadable` events, and
            // a closing `state` with the record's state is written after
            // them, so the log is whole again, and the record follows it.
            let closed = record.state.isTerminal && !replay.contains(where: Self.isFinalState)
            if closed {
                replay += closingEvents(record, after: replay, skipped: trailing)
            }
            // The event log is the truth: a record written before the events
            // after it takes the last one's number, and one written ahead of
            // a lost line is pulled back to the last event that survived.
            record.lastSeq = replay.last?.seq ?? .start
            // So is its state: `append` writes the line before the record,
            // and a host that died between the two left a record still
            // running behind a final `state`. Resuming that task would start
            // a finished build over and delete its artifact. The record keeps
            // no result or message of its own; those stay in the event.
            // Only forward: a record already final stays so, since a final
            // `state` line that no longer decodes leaves an earlier
            // `running` as the last one read, and resuming over it would
            // delete the finished build all the same.
            var moved = false
            if !record.state.isTerminal,
               let last = replay.last(where: { $0.kind == TaskEvent.stateKind }),
               let name = last.payload?["state"]?.stringValue,
               let state = TaskState(rawValue: name),
               state != record.state
            {
                record.state = state
                moved = true
            }
            records[record.id] = record
            events[record.id] = replay
            if closed || moved {
                persist(record.id)
            }
            if !record.state.isTerminal {
                unfinished.append(record)
            }
        }
        dropSupersededAgentTasks()
        return unfinished.sorted { $0.createdAt < $1.createdAt }
    }

    /// Ends a task the host could not resume, saying why when it knows.
    func interrupt(_ id: TaskID, message: String = "The background service stopped while this task was running. Start the task again.") {
        finish(id, .interrupted, message: message)
    }

    /// Records how to resume the task; written to disk at once.
    func setResume(_ id: TaskID, _ value: JSONValue?) {
        guard var record = records[id], !record.state.isTerminal else { return }
        record.resume = value
        records[id] = record
        persist(id)
    }

    func create(kind: TaskKind, owner: WorkerRole?, ownerKey: String? = nil) -> TaskHandle {
        let now = Date()
        let id = TaskID.make()
        records[id] = Record(
            id: id,
            kind: kind,
            state: .running,
            createdAt: now,
            updatedAt: now,
            lastSeq: .start,
            owner: owner,
            ownerKey: ownerKey,
            cancelRequested: false,
            resume: nil,
        )
        events[id] = []
        persist(id)
        if kind == .agent, let ownerKey {
            dropSupersededAgentTasks(of: ownerKey)
        }
        return TaskHandle(taskID: id, kind: kind)
    }

    func record(_ id: TaskID) -> Record? {
        records[id]
    }

    /// Appends an event and numbers it. A `state` event with a `state` field
    /// moves the task; once terminal, nothing more is appended.
    ///
    /// The record is written again only when the event moves the task. Its
    /// number and time are the event's, which `load` reads back from the
    /// log; rewriting it for every event held the registry, which every
    /// request goes through, for as long as a reopened conversation took to
    /// relay its history, tens of thousands of events.
    @discardableResult
    func append(_ id: TaskID, kind: String, payload: JSONValue?) -> TaskEvent? {
        guard var record = records[id], !record.state.isTerminal else { return nil }
        let event = TaskEvent(seq: record.lastSeq.next, kind: kind, payload: payload)
        record.lastSeq = event.seq
        record.updatedAt = event.time
        var moved = false
        if kind == TaskEvent.stateKind,
           let name = payload?["state"]?.stringValue,
           let state = TaskState(rawValue: name),
           state != record.state
        {
            record.state = state
            moved = true
        }
        records[id] = record
        events[id, default: []].append(event)
        appendEventToDisk(id, event)
        if moved {
            persist(id)
        }
        wake(id)
        return event
    }

    func finish(_ id: TaskID, _ state: TaskState, message: String? = nil) {
        var payload: [String: JSONValue] = ["state": .string(state.rawValue)]
        if let message {
            payload["message"] = .string(message)
        }
        append(id, kind: TaskEvent.stateKind, payload: .object(payload))
    }

    /// The long poll behind every attach.
    func attach(
        _ id: TaskID,
        as operation: AppOperation,
        afterSeq: EventSeq,
        waitMilliseconds: Int,
    ) async throws -> TaskEventBatch {
        guard let record = records[id] else { throw ApelinError(.notFound, "This task could not be found.") }
        guard record.kind.attachOperation == operation else {
            throw ApelinError(.badRequest, "task \(id) is read with \(record.kind.attachOperation.rawValue)")
        }
        if pending(id, afterSeq).isEmpty, !record.state.isTerminal, waitMilliseconds > 0 {
            let wait = min(waitMilliseconds, Self.maximumWaitMilliseconds)
            let token = UUID()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[id, default: [:]][token] = continuation
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                    self.timeOut(id, token)
                }
            }
        }
        let current = records[id] ?? record
        let batch = pending(id, afterSeq)
        let last = batch.last?.seq ?? max(afterSeq, .start)
        return TaskEventBatch(
            taskID: id,
            events: batch,
            state: current.state,
            lastSeq: last,
            finished: current.state.isTerminal && last >= current.lastSeq,
        )
    }

    /// The newest event of `kind` whose payload has `field` equal to `value`,
    /// searched over the whole log rather than one attach batch.
    func lastEvent(_ id: TaskID, kind: String, field: String, equals value: String) -> TaskEvent? {
        events[id]?.last { $0.kind == kind && $0.payload?[field]?.stringValue == value }
    }

    /// The newest event of `kind`, searched over the whole log.
    func lastEvent(_ id: TaskID, kind: String) -> TaskEvent? {
        events[id]?.last { $0.kind == kind }
    }

    /// Every task of `kind`, finished or not, in no order.
    func records(kind: TaskKind) -> [Record] {
        records.values.filter { $0.kind == kind }
    }

    /// Marks the cancel; the caller tells the owning worker. A task with no
    /// worker to stop it ends here.
    func requestCancel(_ id: TaskID) throws -> Record {
        guard var record = records[id] else { throw ApelinError(.notFound, "This task could not be found.") }
        guard !record.state.isTerminal else { return record }
        record.cancelRequested = true
        records[id] = record
        persist(id)
        return record
    }

    /// Tasks a worker served when it went away end as failed.
    func ownerExited(role: WorkerRole, key: String?) {
        for record in records.values where record.owner == role && record.ownerKey == key && !record.state.isTerminal {
            finish(record.id, record.cancelRequested ? .cancelled : .failed, message: "The background process for this task stopped.")
        }
    }

    func hasActiveTask(owner role: WorkerRole, key: String?) -> Bool {
        records.values.contains { $0.owner == role && $0.ownerKey == key && !$0.state.isTerminal }
    }

    var activeCount: Int {
        records.values.filter { !$0.state.isTerminal }.count
    }

    /// Active tasks by kind, for the work report.
    var activeByKind: [String: Int] {
        records.values.filter { !$0.state.isTerminal }.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 }
    }

    // MARK: Private

    /// Removes, records and logs both, every finished agent task a newer
    /// task of the same session supersedes, of `session` or of every one.
    /// Each reopen of a session starts a task that replays its whole history,
    /// and `load` reads every log back into memory before the host answers
    /// anything: a conversation reopened ten times left ten copies, 69 MB
    /// read at each start. Only a session's newest task is ever read again
    /// (`AgentConversationList`), so it is kept, finished or not, and so is
    /// every task still running.
    private func dropSupersededAgentTasks(of session: String? = nil) {
        var bySession: [String: [Record]] = [:]
        for record in records.values where record.kind == .agent {
            guard let key = record.ownerKey, session == nil || key == session else { continue }
            bySession[key, default: []].append(record)
        }
        for tasks in bySession.values where tasks.count > 1 {
            let order = { (record: Record) in (record.createdAt, record.lastSeq.rawValue, record.id.rawValue) }
            let newest = tasks.max { order($0) < order($1) }
            for record in tasks where record.id != newest?.id && record.state.isTerminal {
                records.removeValue(forKey: record.id)
                events.removeValue(forKey: record.id)
                unlink(eventsURL(record.id).path)
                unlink(recordURL(record.id).path)
            }
        }
    }

    private func pending(_ id: TaskID, _ afterSeq: EventSeq) -> [TaskEvent] {
        let all = events[id] ?? []
        // Events are numbered 1…n with no gaps, so index = seq - 1.
        let start = Int(min(UInt64(all.count), afterSeq.rawValue))
        return Array(all[start...].prefix(1000))
    }

    private func wake(_ id: TaskID) {
        let waiting = waiters.removeValue(forKey: id) ?? [:]
        waiting.values.forEach { $0.resume() }
    }

    private func timeOut(_ id: TaskID, _ token: UUID) {
        waiters[id]?.removeValue(forKey: token)?.resume()
    }

    private func recordURL(_ id: TaskID) -> URL {
        directory.appendingPathComponent("\(id.rawValue).json")
    }

    private func eventsURL(_ id: TaskID) -> URL {
        directory.appendingPathComponent("\(id.rawValue).events.jsonl")
    }

    private func persist(_ id: TaskID) {
        guard let record = records[id], let data = try? JSONCoding.encode(record) else { return }
        try? data.write(to: recordURL(id), options: .atomic)
    }

    private func appendEventToDisk(_ id: TaskID, _ event: TaskEvent) {
        guard var line = try? JSONCoding.encode(event) else { return }
        line.append(0x0A)
        let url = eventsURL(id)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// What stands in for a line of the log this build cannot read.
    static let unreadableKind = "unreadable"

    static func isFinalState(_ event: TaskEvent) -> Bool {
        event.kind == TaskEvent.stateKind
            && event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:))?.isTerminal == true
    }

    /// What ends the replay of a finished task whose final `state` line
    /// cannot be read: an `unreadable` event for each whole line skipped
    /// after the last that read, then a `state` with the record's own state,
    /// appended to the log. The skipped lines stay in the file, so the next
    /// load fills the same numbers and reads this `state` after them.
    private func closingEvents(_ record: Record, after replay: [TaskEvent], skipped: UInt64) -> [TaskEvent] {
        var closing: [TaskEvent] = []
        var seq = UInt64(replay.count)
        for _ in 0 ..< skipped {
            seq += 1
            closing.append(Self.unreadable(EventSeq(seq), time: record.updatedAt))
        }
        let state = TaskEvent(
            seq: EventSeq(seq + 1),
            kind: TaskEvent.stateKind,
            time: record.updatedAt,
            payload: .object([
                "state": .string(record.state.rawValue),
                "message": .string("The task ended, but its final details could not be read."),
            ]),
        )
        appendEventToDisk(record.id, state)
        closing.append(state)
        return closing
    }

    private static func unreadable(_ seq: EventSeq, time: Date) -> TaskEvent {
        TaskEvent(
            seq: seq,
            kind: unreadableKind,
            time: time,
            payload: .object(["message": .string("this line of the task's log could not be read")]),
        )
    }

    /// The events in the log, numbered 1…n with no gap, as `pending` and
    /// every attach rely on, and how many whole lines past the last one that
    /// read were skipped.
    ///
    /// Only a torn tail is cut off the file: a last fragment with no newline
    /// (the line a crash stopped writing) that does not decode or is out of
    /// order. Cutting it lets the next event appended start a line of its own
    /// instead of joining the torn one and being lost with it at the next
    /// load; a last event that lost only its newline keeps its place and
    /// gets one.
    ///
    /// A line with its newline was written whole, so one that does not
    /// decode (a corrupted line, or a newer build's event shape met after a
    /// downgrade) stays in the file and reading goes on past it. Stopping
    /// there would drop the final `state` behind it, so the task would be
    /// resumed or interrupted over its real end, and the events appended
    /// after that, past the gap, would never be read back. Instead, when the
    /// next event that reads names a higher number, each number the skipped
    /// lines held is filled with an `unreadable` event: the numbering keeps
    /// no gap and an attach still reaches the final state. A jump larger
    /// than the skipped lines can account for makes that line a bad one too,
    /// and a number already read (appended after a bad last line, once that
    /// line reads again) is passed over.
    private func readEvents(_ id: TaskID) -> (events: [TaskEvent], skipped: UInt64) {
        let url = eventsURL(id)
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let decoder = JSONCoding.decoder()
        var result: [TaskEvent] = []
        var skipped: UInt64 = 0
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 0x0A)
            let line = Data(data[start ..< (newline ?? data.endIndex)])
            let expected = UInt64(result.count + 1)
            let event = try? decoder.decode(TaskEvent.self, from: line)
            if let event, event.seq.rawValue >= expected, event.seq.rawValue - expected <= skipped {
                while UInt64(result.count + 1) < event.seq.rawValue {
                    result.append(Self.unreadable(EventSeq(UInt64(result.count + 1)), time: event.time))
                }
                result.append(event)
                skipped = 0
                if newline == nil, let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(Data([0x0A]))
                    try? handle.close()
                }
            } else if newline == nil {
                truncate(url.path, off_t(start - data.startIndex))
            } else if (event?.seq.rawValue ?? .max) > expected {
                skipped += 1
            }
            guard let newline else { break }
            start = data.index(after: newline)
        }
        return (result, skipped)
    }
}

/// Worker events, applied one at a time in the order the channel delivered
/// them. A task per event would let a later one overtake an earlier one that
/// awaits something first (a build's `artifact` is recorded before it is
/// appended), and once the final `state` is in, the registry drops whatever
/// arrives after it.
final class TaskEventFeed<Item: Sendable>: Sendable {
    private let continuation: AsyncStream<Item>.Continuation

    init(_ apply: @escaping @Sendable (Item) async -> Void) {
        var continuation: AsyncStream<Item>.Continuation!
        let stream = AsyncStream<Item>(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        Task {
            for await item in stream {
                await apply(item)
            }
        }
    }

    func send(_ item: Item) {
        continuation.yield(item)
    }

    deinit {
        continuation.finish()
    }
}
