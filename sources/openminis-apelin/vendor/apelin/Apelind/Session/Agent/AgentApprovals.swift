import ApelinCore
import ApelinProtocol
import Foundation

/// The host's side of an agent session's approvals: what the app approved is
/// matched against the session's own `approvalRequested` event, never against
/// what the agent says it asked.
enum AgentApprovals {
    /// The payload of the session's own `approvalRequested` event for
    /// `approvalID`, read from the registry wherever it is in the session's
    /// log: an attach batch stops at a thousand events, a long session does
    /// not.
    static func requested(
        _ approvalID: String,
        entry: AgentSessionTable.Entry,
        registry: TaskRegistry,
    ) async -> JSONValue? {
        await registry.lastEvent(
            entry.task.taskID,
            kind: "approvalRequested",
            field: "approvalID",
            equals: approvalID,
        )?.payload
    }

    /// Relays the app's decision: recorded in the session table (and, for an
    /// approval, in the host's ledger) before `forward` hands it to the
    /// worker, so the host knows it when the worker acts on it at once, and
    /// taken back when the worker did not accept it, so the host never holds
    /// a grant the worker was not given. A shell_run approved for the
    /// session also leaves a session grant for that command in that
    /// directory (`recordSessionGrant`).
    static func relay<Reply>(
        _ approve: AgentApproveRequest,
        registry: TaskRegistry,
        ledger: ApprovalLedger,
        forward: () async -> Reply,
        accepted: (Reply) -> Bool,
    ) async throws -> Reply {
        let sessions = AgentSessionTable.shared
        // A command as root is approved only where the app checked the
        // device owner first; the console, which runs script files, never
        // says it did.
        if approve.decision == .approve, approve.ownerVerified != true,
           let entry = await sessions.entry(approve.sessionID),
           await isRootRequest(requested(approve.approvalID, entry: entry, registry: registry))
        {
            throw ApelinError(
                .denied,
                "a command that runs as root is approved only in the conversation, with Face ID, Touch ID or the passcode",
            )
        }
        let previous = await sessions.entry(approve.sessionID)?.approvals[approve.approvalID]
        await sessions.record(approve.sessionID, approvalID: approve.approvalID, decision: approve.decision)
        var grant: LedgerGrant?
        var sessionGrant: RunCodeGrant?
        var reached: String?
        if approve.decision == .approve, let entry = await sessions.entry(approve.sessionID) {
            do {
                grant = try await recordInLedger(approve, entry: entry, registry: registry, ledger: ledger)
            } catch {
                await sessions.record(approve.sessionID, approvalID: approve.approvalID, decision: previous)
                throw error
            }
            sessionGrant = await recordSessionGrant(approve, entry: entry, registry: registry)
            reached = await recordProjectReach(approve, entry: entry, registry: registry)
        }
        let reply = await forward()
        guard !accepted(reply) else {
            if case let .description(granted) = grant {
                await ledger.confirmApproval(granted)
            }
            return reply
        }
        await sessions.record(approve.sessionID, approvalID: approve.approvalID, decision: previous)
        if let sessionGrant {
            await sessions.removeGrant(approve.sessionID, sessionGrant)
        }
        if let reached {
            await sessions.forgetProject(reached, session: approve.sessionID)
        }
        switch grant {
        case let .description(granted):
            try? await ledger.withdrawApproval(granted)
        case let .removal(installationID):
            _ = await ledger.takeRemoval(installationID: installationID, session: approve.sessionID)
        case nil:
            break
        }
        return reply
    }

    /// Records a session grant when the app approved, for the session, a
    /// shell_run request that offered it: the command its `detail.command`
    /// showed in its `workingDirectory`, normalised as `authorize` compares
    /// them. Answers the grant when it is new, nil when it added nothing.
    private static func recordSessionGrant(
        _ approve: AgentApproveRequest,
        entry: AgentSessionTable.Entry,
        registry: TaskRegistry,
    ) async -> RunCodeGrant? {
        guard approve.scope == .session,
              let asked = await requested(approve.approvalID, entry: entry, registry: registry),
              asked["tool"]?.stringValue == AgentToolName.shellRun.rawValue, asked["allowsSessionScope"] == .bool(true),
              !isRootRequest(asked), let spec = approvedSpec(asked)
        else { return nil }
        let grant = RunCodeGrant(spec: spec, directory: directoryName(asked["workingDirectory"]?.stringValue))
        return await AgentSessionTable.shared.addGrant(entry.sessionID, grant) ? grant : nil
    }

    /// Lets the session reach another project once the app approved a
    /// conversation call of this session naming it (`detail.otherProject`):
    /// its list and its conversations' tasks, which the agent's gate still
    /// asks about one call at a time. Answers the project when it is new.
    private static func recordProjectReach(
        _ approve: AgentApproveRequest,
        entry: AgentSessionTable.Entry,
        registry: TaskRegistry,
    ) async -> String? {
        guard let asked = await requested(approve.approvalID, entry: entry, registry: registry),
              let projectID = asked["detail"]?[AgentConversationRules.otherProjectDetail]?["projectID"]?.stringValue,
              projectID != entry.project.id
        else { return nil }
        return await AgentSessionTable.shared.allowProject(projectID, session: entry.sessionID) ? projectID : nil
    }

    /// Spends one approval the app gave this session whose own
    /// `approvalRequested` event `covers` accepts; false when there is none.
    /// What was asked is read from the registry, never from the request.
    static func spend(
        entry: AgentSessionTable.Entry,
        registry: TaskRegistry,
        covers: (JSONValue) -> Bool,
    ) async -> Bool {
        for approvalID in await AgentSessionTable.shared.approvedIDs(entry.sessionID) {
            guard let asked = await requested(approvalID, entry: entry, registry: registry), covers(asked) else {
                continue
            }
            if await AgentSessionTable.shared.consume(entry.sessionID, approvalID: approvalID) {
                return true
            }
        }
        return false
    }

    /// What an approval added to the ledger.
    enum LedgerGrant {
        case description(ApprovalLedger.Grant)
        case removal(installationID: String)
    }

    /// Records an approval of a changed description or a package removal in
    /// the ledger; answers what it added, nil when it added nothing.
    @discardableResult
    static func recordInLedger(
        _ approve: AgentApproveRequest,
        entry: AgentSessionTable.Entry,
        registry: TaskRegistry,
        ledger: ApprovalLedger,
    ) async throws -> LedgerGrant? {
        let asked = await requested(approve.approvalID, entry: entry, registry: registry)
        guard let detail = asked?["detail"] else { return nil }
        if let changed = detail["descriptionChanged"],
           let kindName = changed["kind"]?.stringValue, let kind = ApprovalDescriptionKind(rawValue: kindName),
           let digest = changed["digest"]?.stringValue
        {
            guard let grant = try await ledger.recordApproval(digest, kind: kind, project: entry.project.id) else {
                return nil
            }
            return .description(grant)
        } else if let removal = detail["packageRemoval"], let installationID = removal["installationID"]?.stringValue {
            guard await ledger.allowRemoval(installationID: installationID, session: entry.sessionID) else {
                return nil
            }
            return .removal(installationID: installationID)
        }
        return nil
    }

    /// Whether the session may run `run`, and as whom: as root only for a
    /// root request (`authorizeRoot`); as mobile otherwise, under Confirm as
    /// a preset with the preset to run in its place (`AgentRunCode.preset`).
    /// While the session asks before the screen is used, a command that runs
    /// icli or another of `ScreenConsent.programs` runs, in every mode, only
    /// on the one approval the user gave for exactly it (`AgentScreenRules`).
    @discardableResult
    static func authorize(
        _ run: AgentRunCodeRequest,
        entry: AgentSessionTable.Entry,
        registry: TaskRegistry,
        ledger: ApprovalLedger,
        installRoot: String,
    ) async throws -> AgentRunCode.Identity {
        if entry.asksBeforeScreen, ScreenConsent.usesScreen(run.spec) {
            if run.asRoot == true {
                try await requireLive(entry, registry: registry)
            }
            try await AgentScreenRules.spend(run, entry: entry, registry: registry)
            return run.asRoot == true ? .root : .mobile(preset: nil)
        }
        if run.asRoot == true {
            try await authorizeRoot(run, entry: entry, registry: registry, ledger: ledger)
            return .root
        }
        if !entry.mode.asks {
            return .mobile(preset: nil)
        }
        switch run.approval {
        case .relaxed:
            throw ApelinError(.denied, "this session is in Strict mode")
        case .preset:
            let project = entry.project.path
            let directory = try AgentRunCode.workingDirectory(run.workingDirectory, project: project)
            guard let preset = await AgentRunCode.preset(
                run.spec,
                directory: directory,
                project: project,
                installRoot: installRoot,
            ) else {
                throw RunCodeApproval.presetRefusal
            }
            return .mobile(preset: preset)
        case let .user(approvalID):
            // The approval must be one this session asked for shell_run, for
            // this command in this directory, checked before it is spent so
            // a refused call leaves it alone.
            let asked = await requested(approvalID, entry: entry, registry: registry)
            guard let asked, asked["tool"]?.stringValue == AgentToolName.shellRun.rawValue else {
                throw ApelinError(.denied, "\(approvalID) is not an approval this session requested for shell_run")
            }
            guard let approved = approvedSpec(asked), approved == run.spec,
                  directoryName(asked["workingDirectory"]?.stringValue) == directoryName(run.workingDirectory)
            else {
                throw ApelinError(.denied, "\(approvalID) was given for another command or working directory")
            }
            guard await AgentSessionTable.shared.consume(run.sessionID, approvalID: approvalID) else {
                throw ApelinError(.denied, "the app has not approved \(approvalID)")
            }
            return .mobile(preset: nil)
        case .session:
            // Good for the rest of the session, never spent, and only for a
            // command and directory the app approved for the session.
            let grant = RunCodeGrant(spec: run.spec, directory: directoryName(run.workingDirectory))
            guard await AgentSessionTable.shared.hasGrant(run.sessionID, grant) else {
                throw ApelinError(.denied, "the app has not approved this command in this directory for the session")
            }
            return .mobile(preset: nil)
        }
    }

    /// A root request runs only while the session's task is live, and then
    /// in Full mode — as both the session table and the ledger record it,
    /// the ledger holding an unknown session to Confirm — or with one
    /// approval the app gave this session for a root request
    /// (`rootCommandDetail`) of exactly this command in this directory,
    /// spent here. Never as a preset, never under a session grant, and an
    /// approval of an ordinary request is no approval for it.
    private static func authorizeRoot(
        _ run: AgentRunCodeRequest,
        entry: AgentSessionTable.Entry,
        registry: TaskRegistry,
        ledger: ApprovalLedger,
    ) async throws {
        try await requireLive(entry, registry: registry)
        if entry.mode == .full, await ledger.mode(session: entry.sessionID) == .full {
            return
        }
        guard case let .user(approvalID) = run.approval else {
            throw ApelinError(.denied, "running as root needs the user's approval of this call, every time")
        }
        let asked = await requested(approvalID, entry: entry, registry: registry)
        guard let asked, asked["tool"]?.stringValue == AgentToolName.shellRun.rawValue,
              let approved = approvedSpec(asked, key: RunCodeApproval.rootCommandDetail), approved == run.spec,
              directoryName(asked["workingDirectory"]?.stringValue) == directoryName(run.workingDirectory)
        else {
            throw ApelinError(.denied, "\(approvalID) is not the user's approval of this command as root here")
        }
        guard await AgentSessionTable.shared.consume(run.sessionID, approvalID: approvalID) else {
            throw ApelinError(.denied, "the app has not approved \(approvalID)")
        }
    }

    /// Nothing runs as root for a session whose task has ended.
    private static func requireLive(_ entry: AgentSessionTable.Entry, registry: TaskRegistry) async throws {
        guard let record = await registry.record(entry.task.taskID), !record.state.isTerminal else {
            throw ApelinError(.denied, "this session has ended; nothing more runs as root for it")
        }
    }

    /// Whether `asked`, one of the session's own `approvalRequested` events,
    /// is for a command as root: what the app must check the device owner
    /// for before approving it.
    static func isRootRequest(_ asked: JSONValue?) -> Bool {
        asked?["detail"]?[RunCodeApproval.rootCommandDetail] != nil
    }

    /// The command a shell_run approval request showed the user, as the
    /// `RunCodeSpec` the agent sends for it: apelin-agent puts the classified
    /// invocation in `detail.command` — `detail.rootCommand` for a root
    /// request — (ApelinAgent's `RunCodeInvocation`, in its synthesized
    /// Codable shape) and hands shell text to `sh`
    /// (`ChannelHostBackend.spec`). A request without one approves nothing.
    static func approvedSpec(_ asked: JSONValue, key: String = "command") -> RunCodeSpec? {
        guard let command = asked["detail"]?[key],
              let invocation = try? command.decode(RequestedInvocation.self)
        else { return nil }
        switch invocation {
        case let .argv(argv): return .argv(argv)
        case let .shell(text): return .script(interpreter: "sh", source: text)
        case let .script(interpreter, source): return .script(interpreter: interpreter, source: source)
        }
    }

    /// ApelinAgent's `RunCodeInvocation`, case for case, so it decodes what
    /// that one encodes.
    private enum RequestedInvocation: Decodable {
        case argv([String])
        case shell(String)
        case script(interpreter: String, source: String)
    }

    /// The working directory as both sides spell it, the project root `.`.
    static func directoryName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "." }
        return name
    }
}

/// A shell_run command and working directory the app approved for the rest
/// of a session, as mobile: a root request is never granted for the session.
struct RunCodeGrant: Equatable, Sendable {
    var spec: RunCodeSpec
    /// As both sides spell it, the project root `.`.
    var directory: String
}

/// What the host keeps about each agent session it opened: the project it
/// resolved, the approval mode the app chose and whether it asks before
/// the screen is used (`ScreenConsent`), the approvals the app gave,
/// the shell_run calls it approved for the session, and, for one an agent
/// opened (`AgentConversations`), the session that opened it.
actor AgentSessionTable {
    static let shared = AgentSessionTable()

    struct Entry: Sendable {
        var sessionID: String
        var task: TaskHandle
        var project: ResolvedProject
        var mode: ApprovalMode
        /// Ask Before Using the Screen, as the app last sent it; an agent's
        /// session has its opener's.
        var asksBeforeScreen = true
        var title: String?
        var createdAt: Date
        var approvals: [String: ApprovalDecision] = [:]
        /// The shell_run calls the app approved for the rest of the session.
        var runCodeGrants: [RunCodeGrant] = []
        /// The session whose agent opened this one; nil for the app's.
        var parentSessionID: String?
        /// 0 for a session the app opened, its opener's plus one otherwise.
        var depth = 0
        /// The tasks this session's agent started (setups, imports, git),
        /// the only environment tasks it may read.
        var startedTasks: Set<TaskID> = []
        /// Projects besides its own whose conversations the app let this
        /// session reach, by approving a conversation call naming them.
        var reachableProjects: Set<String> = []
    }

    private var entries: [String: Entry] = [:]
    /// Places held, per project ID, for sessions agents are opening.
    private var reservations: [String: Int] = [:]

    /// `releasingReservation`: the place `reserveChild` held for it is
    /// taken in the same step, so no count misses it in between.
    func add(_ entry: Entry, releasingReservation: Bool = false) {
        if releasingReservation {
            releaseChild(project: entry.project.id)
        }
        entries[entry.sessionID] = entry
    }

    func entry(_ sessionID: String) -> Entry? {
        entries[sessionID]
    }

    /// The session whose agent task is `taskID`.
    func entry(task taskID: TaskID) -> Entry? {
        entries.values.first { $0.task.taskID == taskID }
    }

    /// The sessions of `projectID` whose task has not ended, oldest first:
    /// the ones a deletion of the project closes.
    func running(project projectID: String, registry: TaskRegistry) async -> [Entry] {
        var running: [Entry] = []
        for entry in entries.values.filter({ $0.project.id == projectID }).sorted(by: { $0.createdAt < $1.createdAt }) {
            if let record = await registry.record(entry.task.taskID), !record.state.isTerminal {
                running.append(entry)
            }
        }
        return running
    }

    /// The title the session's agent gave it (its `title` event).
    func setTitle(_ title: String, session: String) {
        entries[session]?.title = title
    }

    /// Holds a place for one more session an agent opens in `project`,
    /// unless `AgentConversations.maximumOpenChildren` of them are running
    /// or being opened. The caller gives it back with `releaseChild`, or
    /// with `add(_:releasingReservation:)` once the session is open.
    func reserveChild(project: String, registry: TaskRegistry) async -> Bool {
        let children = { self.entries.values.filter { $0.project.id == project && $0.parentSessionID != nil } }
        var checked: Set<TaskID> = []
        var running: Set<TaskID> = []
        for child in children() {
            checked.insert(child.task.taskID)
            if let record = await registry.record(child.task.taskID), !record.state.isTerminal {
                running.insert(child.task.taskID)
            }
        }
        // Counted again after the awaits: an open that finished meanwhile
        // is an entry now, and counts as running.
        let count = children().count { running.contains($0.task.taskID) || !checked.contains($0.task.taskID) }
        guard count + reservations[project, default: 0] < AgentConversations.maximumOpenChildren else { return false }
        reservations[project, default: 0] += 1
        return true
    }

    func releaseChild(project: String) {
        guard let held = reservations[project] else { return }
        reservations[project] = held > 1 ? held - 1 : nil
    }

    func setMode(_ mode: ApprovalMode, session: String) {
        entries[session]?.mode = mode
    }

    func setAsksBeforeScreen(_ asks: Bool, session: String) {
        entries[session]?.asksBeforeScreen = asks
    }

    /// Nil forgets the decision.
    func record(_ sessionID: String, approvalID: String, decision: ApprovalDecision?) {
        entries[sessionID]?.approvals[approvalID] = decision
    }

    /// The approvals the app gave the session that are not spent yet, in a
    /// fixed order.
    func approvedIDs(_ sessionID: String) -> [String] {
        (entries[sessionID]?.approvals ?? [:]).filter { $0.value == .approve }.map(\.key).sorted()
    }

    func recordStarted(_ taskID: TaskID, session sessionID: String) {
        entries[sessionID]?.startedTasks.insert(taskID)
    }

    func started(_ taskID: TaskID, session sessionID: String) -> Bool {
        entries[sessionID]?.startedTasks.contains(taskID) == true
    }

    /// Answers whether the project is new to the session.
    func allowProject(_ projectID: String, session sessionID: String) -> Bool {
        guard entries[sessionID] != nil else { return false }
        return entries[sessionID]?.reachableProjects.insert(projectID).inserted == true
    }

    func forgetProject(_ projectID: String, session sessionID: String) {
        entries[sessionID]?.reachableProjects.remove(projectID)
    }

    func mayReach(_ projectID: String, session sessionID: String) -> Bool {
        entries[sessionID]?.reachableProjects.contains(projectID) == true
    }

    /// An approval is good for one run.
    func consume(_ sessionID: String, approvalID: String) -> Bool {
        guard entries[sessionID]?.approvals[approvalID] == .approve else { return false }
        entries[sessionID]?.approvals[approvalID] = nil
        return true
    }

    /// Answers whether the grant is new.
    func addGrant(_ sessionID: String, _ grant: RunCodeGrant) -> Bool {
        guard let entry = entries[sessionID], !entry.runCodeGrants.contains(grant) else { return false }
        entries[sessionID]?.runCodeGrants.append(grant)
        return true
    }

    func removeGrant(_ sessionID: String, _ grant: RunCodeGrant) {
        entries[sessionID]?.runCodeGrants.removeAll { $0 == grant }
    }

    func hasGrant(_ sessionID: String, _ grant: RunCodeGrant) -> Bool {
        entries[sessionID]?.runCodeGrants.contains(grant) == true
    }

    /// The session closed: nothing it was granted holds — no approval it
    /// has not spent (a root one included), no session grant, no project.
    func forgetGrants(_ sessionID: String) {
        entries[sessionID]?.approvals = [:]
        entries[sessionID]?.runCodeGrants = []
        entries[sessionID]?.reachableProjects = []
    }

    /// Every session, or only `projectID`'s, oldest first.
    func summaries(registry: TaskRegistry, projectID: String? = nil) async -> [AgentSessionSummary] {
        var result: [AgentSessionSummary] = []
        let listed = entries.values.filter { projectID == nil || $0.project.id == projectID }
        for entry in listed.sorted(by: { $0.createdAt < $1.createdAt }) {
            let record = await registry.record(entry.task.taskID)
            result.append(AgentSessionSummary(
                sessionID: entry.sessionID,
                task: entry.task,
                projectID: entry.project.id,
                projectName: entry.project.isTemporary ? nil : entry.project.name,
                title: entry.title,
                state: record?.state ?? .interrupted,
                updatedAt: record?.updatedAt ?? entry.createdAt,
                parentSessionID: entry.parentSessionID,
            ))
        }
        return result
    }
}

/// Who opened a session an agent opened, and how deep, kept root's in the
/// host's state directory (`agent-sessions/<id>.json`), never read from
/// mobile's `session.json`: the session table starts empty after a restart,
/// and a session the app opens again keeps its opener, its depth and its
/// place among its project's agent-opened sessions.
enum AgentSessionLineage {
    struct Record: Codable, Equatable {
        var parentSessionID: String
        var depth: Int
    }

    static func save(_ record: Record, session sessionID: String, state: URL) {
        guard let file = file(sessionID, state: state) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        try? JSONCoding.encode(record).write(to: file, options: .atomic)
    }

    static func load(session sessionID: String, state: URL) -> Record? {
        guard let file = file(sessionID, state: state), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONCoding.decode(Record.self, from: data)
    }

    /// Nil unless the session ID is a UUID, so it names one file.
    private static func file(_ sessionID: String, state: URL) -> URL? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        return state.appendingPathComponent("agent-sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).json")
    }
}
