// Terminal: the host opens a PTY, drops the shell to mobile (uid, gid,
// groups, HOME, working directory, privileged fds closed) before exec, and
// hands the app the PTY's I/O as a descriptor. No root shell in M1.
//
// A terminal is a task of kind `terminal`, read with `ptyAttach`. Its events:
// `started` {pid, uid, gid, shell, cwd}, `output` {base64, text?} — every
// byte the shell wrote, numbered like any event, so a reattach replays the
// screen —, `exit` {status, signal?} and the final `state`. Attaching with
// `wantsDescriptor` also hands back one end of a socket: bytes written to it
// are the user's typing, and the shell's output arrives on it live.
// Served by the session host (Apelind/Dispatch/TerminalHandler.swift).

public struct PtyOpenRequest: OperationRequest {
    public typealias Response = PtyOpenResponse
    public static let operation = AppOperation.ptyOpen
    public var columns: Int
    public var rows: Int
    /// A project ID to start in; nil starts in mobile's home.
    public var projectID: String?
    /// Typed into the terminal once the shell is up, as if by the user (the
    /// console's way to drive a terminal; it keeps no descriptors).
    public var initialInput: String?

    public init(columns: Int = 80, rows: Int = 24, projectID: String? = nil, initialInput: String? = nil) {
        self.columns = columns
        self.rows = rows
        self.projectID = projectID
        self.initialInput = initialInput
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns) ?? 80
        rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? 24
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        initialInput = try container.decodeIfPresent(String.self, forKey: .initialInput)
    }
}

public struct PtyOpenResponse: Codable, Sendable, Equatable {
    public var sessionID: String
    /// The terminal task; its events are the session's lifecycle (exit status).
    public var task: TaskHandle

    public init(sessionID: String, task: TaskHandle) {
        self.sessionID = sessionID
        self.task = task
    }
}

/// Attaching to a terminal hands back its I/O descriptor, and also reads its
/// lifecycle events like any attach.
public struct PtyAttachRequest: TaskAttachRequest {
    public static let operation = AppOperation.ptyAttach
    public var taskID: TaskID
    public var afterSeq: EventSeq
    public var waitMilliseconds: Int
    /// Ask for the PTY's I/O descriptor in the reply (descriptor 0).
    public var wantsDescriptor: Bool

    public init(taskID: TaskID, afterSeq: EventSeq = .start, waitMilliseconds: Int = Self.defaultWaitMilliseconds) {
        self.init(taskID: taskID, afterSeq: afterSeq, waitMilliseconds: waitMilliseconds, wantsDescriptor: false)
    }

    public init(taskID: TaskID, afterSeq: EventSeq, waitMilliseconds: Int, wantsDescriptor: Bool) {
        self.taskID = taskID
        self.afterSeq = afterSeq
        self.waitMilliseconds = waitMilliseconds
        self.wantsDescriptor = wantsDescriptor
    }
}

public struct PtyResizeRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.ptyResize
    public var sessionID: String
    public var columns: Int
    public var rows: Int

    public init(sessionID: String, columns: Int, rows: Int) {
        self.sessionID = sessionID
        self.columns = columns
        self.rows = rows
    }
}

public struct PtyCloseRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.ptyClose
    public var sessionID: String
    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

public extension ApelinService {
    func ptyOpen(_ request: PtyOpenRequest = PtyOpenRequest()) async throws -> PtyOpenResponse {
        try await send(request)
    }

    /// The PTY's I/O descriptor, owned by the caller, beside the batch.
    func ptyAttach(taskID: TaskID) async throws -> (TaskEventBatch, OwnedDescriptor?) {
        let request = PtyAttachRequest(taskID: taskID, afterSeq: .start, waitMilliseconds: 0, wantsDescriptor: true)
        let (batch, descriptors) = try await sendReturningDescriptors(request)
        return (batch, descriptors.first)
    }

    func ptyResize(sessionID: String, columns: Int, rows: Int) async throws {
        _ = try await send(PtyResizeRequest(sessionID: sessionID, columns: columns, rows: rows))
    }

    func ptyClose(sessionID: String) async throws {
        _ = try await send(PtyCloseRequest(sessionID: sessionID))
    }
}
