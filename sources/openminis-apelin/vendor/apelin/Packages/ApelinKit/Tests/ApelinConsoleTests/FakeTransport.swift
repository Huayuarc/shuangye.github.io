import ApelinConsole
import ApelinCore
import ApelinProtocol
import Foundation

/// An `ApelinTransport` that records every request and answers what the
/// test set up: a canned reply or error per operation, and for a task the
/// events an attach reads (after its `afterSeq`, like the host's registry).
/// An operation with nothing set up answers `{}` (`Acknowledged`).
final class FakeTransport: ApelinTransport, @unchecked Sendable {
    struct Call {
        var operation: AppOperation
        var payload: JSONValue
        var descriptorCount: Int
    }

    private struct FakeTask {
        var events: [TaskEvent]
        var state: TaskState
        /// The first attach sees only this many events, still running.
        var firstBatch: Int?
    }

    private let lock = PthreadLock()
    private var recorded: [Call] = []
    private var replies: [AppOperation: Result<JSONValue, ApelinError>] = [:]
    private var tasks: [String: FakeTask] = [:]

    var calls: [Call] {
        lock.withLock { recorded }
    }

    var operations: [AppOperation] {
        calls.map(\.operation)
    }

    func reply(_ operation: AppOperation, with value: some Encodable) {
        let json = (try? JSONValue(encoding: value)) ?? .null
        lock.withLock { replies[operation] = .success(json) }
    }

    func fail(_ operation: AppOperation, _ error: ApelinError) {
        lock.withLock { replies[operation] = .failure(error) }
    }

    /// A task an attach reads: these events, then `state` once they are all
    /// delivered. A non-terminal state with every event read answers an
    /// empty batch, as a long poll that ran out does.
    /// With `firstBatch`, the first attach answers only that many events and
    /// `running`, as a task still at work when it was first read.
    func task(_ taskID: String, events: [TaskEvent], state: TaskState, firstBatch: Int? = nil) {
        lock.withLock { tasks[taskID] = FakeTask(events: events, state: state, firstBatch: firstBatch) }
    }

    func call(_ request: WireRequest, descriptors: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor]) {
        let payload = (try? JSONCoding.decode(JSONValue.self, from: request.payload)) ?? .null
        let (reply, attach): (Result<JSONValue, ApelinError>?, Bool) = lock.withLock {
            recorded.append(Call(operation: request.operation, payload: payload, descriptorCount: descriptors.count))
            return (replies[request.operation], tasks.isEmpty == false)
        }
        if attach, let batch = batch(for: request.operation, payload: payload) {
            // A long poll that ran out, briefly, so a follow does not spin.
            if batch.events.isEmpty, !batch.finished {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return (.success(request.requestID, batch), [])
        }
        switch reply {
        case let .failure(error)?:
            return (.failure(request.requestID, error), [])
        case let .success(json)?:
            return try (WireReply(requestID: request.requestID, result: .success(JSONCoding.encode(json))), [])
        case nil:
            return (.success(request.requestID, Acknowledged()), [])
        }
    }

    private func batch(for operation: AppOperation, payload: JSONValue) -> TaskEventBatch? {
        guard operation.requestType is any TaskAttachRequest.Type else { return nil }
        let id = payload["taskID"]?.stringValue ?? payload["stream"]?.stringValue
        guard let id, let task = lock.withLock({ tasks[id] }) else { return nil }
        let after = UInt64(payload["afterSeq"]?.doubleValue ?? 0)
        if let first = task.firstBatch {
            lock.withLock { tasks[id]?.firstBatch = nil }
            let shown = Array(task.events.prefix(first))
            return TaskEventBatch(taskID: TaskID(id), events: shown.filter { $0.seq.rawValue > after }, state: .running,
                                  lastSeq: shown.last?.seq ?? .start, finished: false)
        }
        let events = task.events.filter { $0.seq.rawValue > after }
        let last = task.events.last?.seq ?? .start
        return TaskEventBatch(taskID: TaskID(id), events: events, state: task.state, lastSeq: last, finished: task.state.isTerminal)
    }
}

/// Collects what the console logs, for the tests to read back.
final class RecordingLog: ConsoleLogSink, @unchecked Sendable {
    private let lock = PthreadLock()
    private var collected: [String] = []
    private var problemsSeen: [String] = []

    var lines: [String] {
        lock.withLock { collected }
    }

    var problems: [String] {
        lock.withLock { problemsSeen }
    }

    func line(_ text: String) {
        lock.withLock { collected.append(text) }
    }

    func problem(_ text: String) {
        lock.withLock { problemsSeen.append(text) }
    }
}

extension TaskEvent {
    static func state(_ seq: UInt64, _ state: TaskState) -> TaskEvent {
        TaskEvent(seq: EventSeq(seq), kind: TaskEvent.stateKind, time: Date(timeIntervalSince1970: 0), payload: .object(["state": .string(state.rawValue)]))
    }

    static func log(_ seq: UInt64, _ line: String) -> TaskEvent {
        TaskEvent(seq: EventSeq(seq), kind: "log", time: Date(timeIntervalSince1970: 0), payload: .object(["line": .string(line)]))
    }
}
