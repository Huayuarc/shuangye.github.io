/// What a process the session host starts is for. The host records the
/// role when it spawns the process and identifies the process by the
/// socketpair it made, never by anything the process says about itself.
public enum WorkerRole: String, Codable, CaseIterable, Sendable {
    /// Downloads, unpacking, toolchain retargeting, SDK checks, git. Mobile.
    case environment
    /// One build: compile, link, sign, package. Mobile.
    case build
    /// One agent session (KWWKAgent). Mobile.
    case agent
    /// Logs through icli, crashes, screenshots, the UI tree. Mobile.
    case diagnostics
    /// System log reading that needs root. System libraries only.
    case logReader

    /// The executable's name under `<install root>/usr/libexec/apelin/`.
    public var executableName: String {
        switch self {
        case .environment: "apelin-environment"
        case .build: "apelin-build"
        case .agent: "apelin-agent"
        case .diagnostics: "apelin-diagnostics"
        case .logReader: "apelin-log-reader"
        }
    }

    /// Relative to the install root `hello` answers.
    public var relativePath: String {
        "/usr/libexec/apelin/" + executableName
    }

    /// Every role but the log reader runs as mobile (uid and gid 501).
    public var runsAsRoot: Bool {
        self == .logReader
    }

    public static let mobileUID: UInt32 = 501
    public static let mobileGID: UInt32 = 501
}

/// The first frame the host sends a worker: who it is to be. A worker whose
/// binary serves another role exits.
public struct WorkerAssignment: Codable, Sendable, Equatable {
    public var role: WorkerRole
    public var protocolVersion: Int64
    /// The install root apelind derived from its own path.
    public var installRoot: String
    /// Mobile's home: `<jbroot>/var/mobile` on roothide, `/var/mobile` on rootless.
    public var home: String
    /// The agent or tool session this worker serves, if any.
    public var sessionID: String?

    public init(
        role: WorkerRole,
        protocolVersion: Int64 = Wire.protocolVersion,
        installRoot: String,
        home: String,
        sessionID: String? = nil,
    ) {
        self.role = role
        self.protocolVersion = protocolVersion
        self.installRoot = installRoot
        self.home = home
        self.sessionID = sessionID
    }
}

/// Names of control frames between the host and a worker.
public enum WorkerControl {
    /// host → worker, body `WorkerAssignment`.
    public static let assign = "assign"
    /// worker → host, empty body: the assignment was accepted.
    public static let ready = "ready"
    /// host → worker, frame `taskID` set: stop that task.
    public static let cancel = "cancel"
    /// session host → proxy, body `WorkReport`.
    public static let work = "work"
    /// proxy → session host: persist and exit.
    public static let shutdown = "shutdown"
}

/// How much work the session host holds; the proxy stays up while any.
/// Every kind of work counts: a build, an environment task, a terminal, an
/// agent session and an install are tasks (`tasksByKind` names which), a
/// live worker or agent tool extension is a process. The connected app is
/// counted by the proxy itself.
public struct WorkReport: Codable, Sendable, Equatable {
    public var activeTasks: Int
    public var workers: Int
    /// Open agent tool extension sessions.
    public var toolHosts: Int
    /// Active tasks by `TaskKind` raw value.
    public var tasksByKind: [String: Int]

    public init(activeTasks: Int, workers: Int, toolHosts: Int = 0, tasksByKind: [String: Int] = [:]) {
        self.activeTasks = activeTasks
        self.workers = workers
        self.toolHosts = toolHosts
        self.tasksByKind = tasksByKind
    }

    public var isIdle: Bool {
        activeTasks == 0 && workers == 0 && toolHosts == 0
    }
}
