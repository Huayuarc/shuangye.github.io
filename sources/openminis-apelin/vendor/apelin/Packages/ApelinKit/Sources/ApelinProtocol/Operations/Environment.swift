// Environment tasks (toolchain setup and removal, SDK import), read and
// cancelled through the session host's task registry.
// Served by the session host (Apelind/Session/TaskRegistry.swift).

public struct EnvironmentAttachRequest: TaskAttachRequest {
    public static let operation = AppOperation.environmentAttach
    public var taskID: TaskID
    public var afterSeq: EventSeq
    public var waitMilliseconds: Int

    public init(taskID: TaskID, afterSeq: EventSeq = .start, waitMilliseconds: Int = Self.defaultWaitMilliseconds) {
        self.taskID = taskID
        self.afterSeq = afterSeq
        self.waitMilliseconds = waitMilliseconds
    }
}

public struct EnvironmentCancelRequest: TaskCancelRequest {
    public static let operation = AppOperation.environmentCancel
    public var taskID: TaskID
    public init(taskID: TaskID) {
        self.taskID = taskID
    }
}

public extension ApelinService {
    func environmentAttach(_ request: EnvironmentAttachRequest) async throws -> TaskEventBatch {
        try await send(request)
    }

    func environmentCancel(taskID: TaskID) async throws {
        _ = try await send(EnvironmentCancelRequest(taskID: taskID))
    }
}
