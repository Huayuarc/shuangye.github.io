import Foundation

// Logs and crashes: a bounded, filtered system log stream (icli in
// apelin-diagnostics; apelin-log-reader only where root is needed), crash
// reports listed by ID and opened as a read-only descriptor.
// Served by apelin-diagnostics (Workers/Diagnostics; Packages/ApelinDiagnostics)
// through the session host.

/// The unified log is read live on iOS: a stream listens for
/// `windowSeconds` (default 30, at most 600) and then ends `succeeded`.
public struct LogFilter: Codable, Sendable, Equatable {
    /// Keeps this subsystem and its dotted children.
    public var subsystem: String?
    /// Exact process name, compared case-insensitively.
    public var process: String?
    public var since: Date?
    /// The minimum level: `debug`, `info`, `default`, `error`, `fault`.
    public var level: String?
    /// At most this many `log` events in all (default 1000, at most 5000).
    public var limit: Int?
    /// Case-sensitive substring of the message.
    public var messageContains: String?
    /// How long the stream listens, 1–600 seconds.
    public var windowSeconds: Double?

    public init(
        subsystem: String? = nil,
        process: String? = nil,
        since: Date? = nil,
        level: String? = nil,
        limit: Int? = nil,
        messageContains: String? = nil,
        windowSeconds: Double? = nil,
    ) {
        self.subsystem = subsystem
        self.process = process
        self.since = since
        self.level = level
        self.limit = limit
        self.messageContains = messageContains
        self.windowSeconds = windowSeconds
    }
}

/// A long poll like every attach. The first call carries `filter` and no
/// `stream`, and opens one (a task of kind `logStream`); later calls carry
/// the `stream` from `TaskEventBatch.taskID` and the last `seq` seen. Each
/// event is `log` with {time, process, subsystem, category, level, message}.
public struct LogStreamRequest: TaskAttachRequest {
    public static let operation = AppOperation.logStream
    public var filter: LogFilter?
    public var stream: TaskID?
    public var afterSeq: EventSeq
    public var waitMilliseconds: Int

    public var taskID: TaskID {
        stream ?? TaskID("")
    }

    public init(taskID: TaskID, afterSeq: EventSeq = .start, waitMilliseconds: Int = Self.defaultWaitMilliseconds) {
        filter = nil
        stream = taskID
        self.afterSeq = afterSeq
        self.waitMilliseconds = waitMilliseconds
    }

    public init(filter: LogFilter, waitMilliseconds: Int = Self.defaultWaitMilliseconds) {
        self.filter = filter
        stream = nil
        afterSeq = .start
        self.waitMilliseconds = waitMilliseconds
    }
}

public struct CrashReportSummary: Codable, Sendable, Equatable {
    public var id: String
    public var process: String
    public var bundleID: String?
    public var date: Date
    public var exceptionType: String?

    public init(id: String, process: String, bundleID: String? = nil, date: Date, exceptionType: String? = nil) {
        self.id = id
        self.process = process
        self.bundleID = bundleID
        self.date = date
        self.exceptionType = exceptionType
    }
}

public struct CrashListRequest: OperationRequest {
    public typealias Response = CrashListResponse
    public static let operation = AppOperation.crashList
    public var process: String?
    public var since: Date?

    public init(process: String? = nil, since: Date? = nil) {
        self.process = process
        self.since = since
    }
}

public struct CrashListResponse: Codable, Sendable, Equatable {
    public var reports: [CrashReportSummary]
    public init(reports: [CrashReportSummary] = []) {
        self.reports = reports
    }
}

public struct CrashOpenRequest: OperationRequest {
    public typealias Response = CrashOpenResponse
    public static let operation = AppOperation.crashOpen
    public var id: String
    public init(id: String) {
        self.id = id
    }
}

public struct CrashOpenResponse: Codable, Sendable, Equatable {
    public var descriptor: DescriptorSlot
    public var size: Int64

    public init(descriptor: DescriptorSlot, size: Int64) {
        self.descriptor = descriptor
        self.size = size
    }
}

/// One frame of a symbolicated thread.
public struct SymbolicatedFrame: Codable, Sendable, Equatable {
    public var index: Int
    public var image: String
    public var address: String
    public var symbol: String?
    public var file: String?
    public var line: Int?

    public init(
        index: Int,
        image: String,
        address: String,
        symbol: String? = nil,
        file: String? = nil,
        line: Int? = nil,
    ) {
        self.index = index
        self.image = image
        self.address = address
        self.symbol = symbol
        self.file = file
        self.line = line
    }
}

/// Symbolicates a report (by the id `crashList` gave) against the dSYMs the
/// project's builds kept, matched by image UUID, and ranks suspects.
/// Served by apelin-diagnostics; a report mobile cannot read is opened by
/// the host by id and passed read-only.
public struct CrashSymbolicateRequest: OperationRequest {
    public typealias Response = CrashSymbolicateResponse
    public static let operation = AppOperation.crashSymbolicate
    public var id: String
    /// The project whose builds' dSYMs to read; nil reads none (names stay
    /// what the report says).
    public var projectID: String?

    public init(id: String, projectID: String? = nil) {
        self.id = id
        self.projectID = projectID
    }
}

public struct CrashSymbolicateResponse: Codable, Sendable, Equatable {
    public var id: String
    public var process: String
    public var exceptionType: String?
    /// The image UUIDs a project dSYM matched.
    public var matchedImageUUIDs: [String]
    /// The crashed (or first) thread.
    public var crashedThread: [SymbolicatedFrame]
    /// Image names, most likely first.
    public var suspects: [String]

    public init(
        id: String,
        process: String,
        exceptionType: String? = nil,
        matchedImageUUIDs: [String] = [],
        crashedThread: [SymbolicatedFrame] = [],
        suspects: [String] = [],
    ) {
        self.id = id
        self.process = process
        self.exceptionType = exceptionType
        self.matchedImageUUIDs = matchedImageUUIDs
        self.crashedThread = crashedThread
        self.suspects = suspects
    }
}

public extension ApelinService {
    func crashSymbolicate(id: String, projectID: String? = nil) async throws -> CrashSymbolicateResponse {
        try await send(CrashSymbolicateRequest(id: id, projectID: projectID))
    }
}

public extension ApelinService {
    /// Opens a log stream; read on with `events(of:)` on the returned
    /// batch's `taskID` as a `.logStream` handle.
    func logStream(_ request: LogStreamRequest) async throws -> TaskEventBatch {
        try await send(request)
    }

    func crashList(process: String? = nil, since: Date? = nil) async throws -> CrashListResponse {
        try await send(CrashListRequest(process: process, since: since))
    }

    func crashOpen(id: String) async throws -> (CrashOpenResponse, OwnedDescriptor?) {
        let (response, descriptors) = try await sendReturningDescriptors(CrashOpenRequest(id: id))
        return (
            response,
            descriptors.indices.contains(response.descriptor.index) ? descriptors[response.descriptor.index] : nil,
        )
    }
}
