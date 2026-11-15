import ApelinCore
import Foundation

/// A long piece of work the session host owns: an environment task, a build,
/// an install, an agent session, a log stream. It outlives the app; the app
/// (or a worker) attaches to it and reads its events.
public struct TaskID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func make() -> TaskID {
        TaskID(UUID().uuidString.lowercased())
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A task's events are numbered from 1 with no gaps. Attaching with
/// `afterSeq: n` replays every event after `n`; 0 replays them all.
public struct EventSeq: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var rawValue: UInt64
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let start = EventSeq(0)
    public var next: EventSeq {
        EventSeq(rawValue + 1)
    }

    public static func < (lhs: EventSeq, rhs: EventSeq) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        String(rawValue)
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TaskState: String, Codable, Sendable {
    case queued
    case running
    /// Suspended until the app answers `agentApprove`; never approves itself.
    case waitingForApproval
    case succeeded
    case failed
    case cancelled
    /// The host stopped (crash, reboot) while it ran and could not resume it.
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted: true
        case .queued, .running, .waitingForApproval: false
        }
    }
}

/// What kind of work a task is; names the attach operation that reads it.
public enum TaskKind: String, Codable, Sendable {
    case environment
    case build
    case install
    case agent
    case terminal
    case logStream
    /// A load check: listen for the marker, maybe respring, answer in the
    /// final `state`. The host owns it so a respring that takes the app
    /// down does not lose the answer.
    case confirmLoaded
    /// A provider sign-in in apelin-agent's `credential-import` instance:
    /// what the user must see or open, then a final `state`. Read with
    /// `agentAttach`; never resumed, since the flow's secrets were the
    /// stopped process's alone.
    case signIn

    /// The operation that attaches to this kind of task.
    public var attachOperation: AppOperation {
        switch self {
        case .environment: .environmentAttach
        case .build, .install: .buildAttach
        case .agent, .signIn: .agentAttach
        case .terminal: .ptyAttach
        case .logStream: .logStream
        case .confirmLoaded: .confirmLoadedAttach
        }
    }
}

/// One event of a task. `kind` is a dotted name the domain chooses
/// (`stage`, `progress`, `diagnostic`, `artifact`, `log`, `approvalRequested`,
/// `state`); `payload` is its data.
public struct TaskEvent: Codable, Sendable, Equatable {
    public var seq: EventSeq
    public var kind: String
    public var time: Date
    public var payload: JSONValue?

    public init(seq: EventSeq, kind: String, time: Date = Date(), payload: JSONValue? = nil) {
        self.seq = seq
        self.kind = kind
        self.time = time
        self.payload = payload
    }

    /// The event every task ends with: `state` with `{"state": …}`.
    public static let stateKind = "state"
}

/// What an operation that starts a task answers.
public struct TaskHandle: Codable, Sendable, Equatable {
    public var taskID: TaskID
    public var kind: TaskKind

    public init(taskID: TaskID, kind: TaskKind) {
        self.taskID = taskID
        self.kind = kind
    }

    public var attachOperation: AppOperation {
        kind.attachOperation
    }
}

/// What every attach answers: the events after `afterSeq` (possibly none,
/// when the wait ran out), the task's state now, and the last sequence number
/// to pass as the next `afterSeq`. `finished` is true once the state is
/// terminal and every event has been delivered.
public struct TaskEventBatch: Codable, Sendable, Equatable {
    public var taskID: TaskID
    public var events: [TaskEvent]
    public var state: TaskState
    public var lastSeq: EventSeq
    public var finished: Bool

    public init(taskID: TaskID, events: [TaskEvent], state: TaskState, lastSeq: EventSeq, finished: Bool) {
        self.taskID = taskID
        self.events = events
        self.state = state
        self.lastSeq = lastSeq
        self.finished = finished
    }
}

/// An attach is a long poll: it answers as soon as there is an event after
/// `afterSeq`, or when `waitMilliseconds` runs out with none, or at once when
/// the task has finished. Replay is just `afterSeq` lower than `lastSeq`.
public protocol TaskAttachRequest: OperationRequest where Response == TaskEventBatch {
    var taskID: TaskID { get }
    var afterSeq: EventSeq { get }
    var waitMilliseconds: Int { get }
    init(taskID: TaskID, afterSeq: EventSeq, waitMilliseconds: Int)
}

public extension TaskAttachRequest {
    static var defaultWaitMilliseconds: Int {
        20000
    }
}

/// The request shape of every cancel.
public protocol TaskCancelRequest: OperationRequest where Response == Acknowledged {
    var taskID: TaskID { get }
}
