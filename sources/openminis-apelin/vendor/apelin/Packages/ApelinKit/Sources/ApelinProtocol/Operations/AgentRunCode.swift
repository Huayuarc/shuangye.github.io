/// `shell_run` as the session host runs it: as mobile — or as root when the
/// request asks and the host allows it —, in the session's project, with no
/// shell unless the invocation is a script. Only the agent worker of
/// `sessionID` may send it; the host refuses it from anyone else, and
/// re-decides the approval itself under Confirm, and for root in every mode.
public enum RunCodeSpec: Codable, Sendable, Equatable {
    /// An executable, then its arguments: a name looked up where the run's
    /// shell would, on its `PATH` with the prepared toolchain's tools first
    /// (a preset and a run as root: the bootstrap's and the system's `bin`
    /// directories alone), or a path, read from the working directory
    /// unless absolute.
    case argv([String])
    /// Source handed to `sh`, `bash`, `zsh`, `python3` or `perl`.
    case script(interpreter: String, source: String)
}

/// What the agent's own gate acted on, which the host checks rather than
/// believes.
public enum RunCodeApproval: Codable, Sendable, Equatable {
    case relaxed
    case preset(String)
    /// An approval the app gave through `agentApprove`, used once.
    case user(approvalID: String)
    /// A call the app approved for the rest of the session
    /// (`AgentApproveRequest.scope`): the host runs it only for the command
    /// and working directory it recorded a session grant for.
    case session

    /// What the host answers for a `.preset` call its own preset rule does
    /// not count: `denied` with the reason `notAPreset`, which the agent
    /// acts on by asking the user. The message is for people only.
    public static let presetRefusal = ApelinError(
        .denied,
        "the host does not recognise this command as a preset; ask the user",
        reason: .notAPreset,
    )

    /// The key of a root request's command in its `approvalRequested`
    /// `detail`, in place of `command`: apelin-agent writes it, the host
    /// binds a root approval to it, and the app's card and the host's banner
    /// say "runs as root" from it. An ordinary request names `command`, so
    /// neither approval can stand in for the other.
    public static let rootCommandDetail = "rootCommand"
}

public struct AgentRunCodeRequest: OperationRequest {
    public typealias Response = AgentRunCodeResponse
    public static let operation = AppOperation.agentRunCode
    public var sessionID: String
    public var spec: RunCodeSpec
    /// Relative to the project root; resolved and checked by the host.
    public var workingDirectory: String
    /// 1–1800.
    public var timeoutSeconds: Int
    public var approval: RunCodeApproval
    /// Run as root instead of mobile. The host runs it so only in Full mode,
    /// or with the app's single-use approval of exactly this root request
    /// (`rootCommandDetail`); never as a preset or under a session grant.
    public var asRoot: Bool?

    public init(
        sessionID: String,
        spec: RunCodeSpec,
        workingDirectory: String = ".",
        timeoutSeconds: Int = 120,
        approval: RunCodeApproval,
        asRoot: Bool? = nil,
    ) {
        self.sessionID = sessionID
        self.spec = spec
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.approval = approval
        self.asRoot = asRoot
    }
}

public struct AgentRunCodeResponse: Codable, Sendable, Equatable {
    /// The exit status, or 128 + signal; -1 when it was killed for time.
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    /// Either stream passed its cap (256 KiB each) or the time ran out.
    public var truncated: Bool
    public var timedOut: Bool
    public var durationMilliseconds: Int

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        truncated: Bool = false,
        timedOut: Bool = false,
        durationMilliseconds: Int = 0,
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.timedOut = timedOut
        self.durationMilliseconds = durationMilliseconds
    }
}

public extension ApelinService {
    func agentRunCode(_ request: AgentRunCodeRequest) async throws -> AgentRunCodeResponse {
        try await send(request)
    }
}
