import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// The conversations an agent lists and reads (`agentList`, `agentAttach`;
/// 2026-10-29). The session table starts empty with every host, and apelind
/// exits once idle, so a conversation not opened again since then was in
/// no list. Besides the table's, an agent's list names every session the
/// registry kept an agent task of: by its newest task, which ended with the
/// host before, read like any ended session, in the project its
/// `session.json` names when that is a project under `Projects/` today.
/// Who may reach a project is decided as for the table's sessions
/// (`AgentConversationRules.mayReach`), never from the file. The app's list
/// is the table's alone: it follows what runs.
///
/// A project's chat lists its own project's, or the one it names. General
/// Chat, which has none, lists every project's it may reach — all of them
/// in Relaxed or Full mode, under Strict only those the user let this
/// session reach — and says how many it left out. Never a temporary chat's.
enum AgentConversationList {
    /// The most sessions listed that have not run since the host started;
    /// the newest are kept.
    static let maximumStoredSessions = 200

    static func list(
        _ request: AgentListRequest,
        caller: AgentSessionTable.Entry,
        table: AgentSessionTable,
        registry: TaskRegistry,
        home: String,
        state: URL,
    ) async throws -> AgentListResponse {
        let (projects, unreached) = try await scope(request, caller: caller, table: table, home: home)
        let running = await table.summaries(registry: registry)
        let listed = running.filter { $0.projectID.map { projects[$0] != nil } ?? false }
        let stored = await stored(
            registry: registry,
            home: home,
            state: state,
            live: Set(running.map(\.sessionID)),
            projects: projects,
        )
        return AgentListResponse(sessions: stored + listed, unreachedProjects: unreached > 0 ? unreached : nil)
    }

    /// Whether `caller` may read task `taskID`: a conversation of its own
    /// project, or of another it may reach, by the task the table or a
    /// list names for it.
    static func mayAttach(
        _ taskID: TaskID,
        caller: AgentSessionTable.Entry,
        table: AgentSessionTable,
        registry: TaskRegistry,
        home: String,
    ) async throws {
        if let target = await table.entry(task: taskID) {
            let reachable = await table.mayReach(target.project.id, session: caller.sessionID)
            try AgentConversationRules.mayRead(taskID, target: target, caller: caller, reachable: reachable)
            return
        }
        if let project = await storedProject(of: taskID, table: table, registry: registry, home: home) {
            let reachable = await table.mayReach(project.id, session: caller.sessionID)
            try AgentConversationRules.mayReach(project, caller: caller, reachable: reachable)
            return
        }
        // No conversation's task: refused.
        try AgentConversationRules.mayRead(taskID, target: nil, caller: caller)
    }

    /// The projects `request` lists for `caller`, by id, and how many
    /// General Chat left out because the user has not let it reach them.
    static func scope(
        _ request: AgentListRequest,
        caller: AgentSessionTable.Entry,
        table: AgentSessionTable,
        home: String,
    ) async throws -> (projects: [String: ResolvedProject], unreached: Int) {
        if request.projectID != nil || request.projectName != nil {
            let named = try AgentProjects.resolve(home: home, projectID: request.projectID, projectName: request.projectName)
            let reachable = await table.mayReach(named.id, session: caller.sessionID)
            try AgentConversationRules.mayReach(named, caller: caller, reachable: reachable)
            return ([named.id: named], 0)
        }
        guard caller.project.isTemporary else {
            return ([caller.project.id: caller.project], 0)
        }
        var projects: [String: ResolvedProject] = [:]
        var unreached = 0
        for project in AgentProjects.all(home: home).values {
            let reachable = await table.mayReach(project.id, session: caller.sessionID)
            if (try? AgentConversationRules.mayReach(project, caller: caller, reachable: reachable)) != nil {
                projects[project.id] = project
            } else {
                unreached += 1
            }
        }
        return (projects, unreached)
    }

    /// The sessions of `projects` the table does not know, each by its
    /// newest agent task, oldest first: at most `maximumStoredSessions`,
    /// the most recently active.
    static func stored(
        registry: TaskRegistry,
        home: String,
        state: URL,
        live: Set<String>,
        projects: [String: ResolvedProject],
    ) async -> [AgentSessionSummary] {
        guard !projects.isEmpty, let sessions = CanonicalPath.resolve(DataFolder(home: home).sessions.path) else {
            return []
        }
        var newest: [String: TaskRegistry.Record] = [:]
        for record in await registry.records(kind: .agent) {
            guard let session = sessionID(of: record), !live.contains(session) else { continue }
            if let kept = newest[session], !isNewer(record, than: kept) {
                continue
            }
            newest[session] = record
        }
        let recent = newest.sorted { ($0.value.updatedAt, $0.key) > ($1.value.updatedAt, $1.key) }
        var listed: [AgentSessionSummary] = []
        for (session, record) in recent where listed.count < maximumStoredSessions {
            guard let id = projectID(of: session, sessions: sessions), let project = projects[id] else { continue }
            let title = await registry.lastEvent(record.id, kind: "title")?.payload?["text"]?.stringValue
            listed.append(AgentSessionSummary(
                sessionID: session,
                task: TaskHandle(taskID: record.id, kind: record.kind),
                projectID: project.id,
                projectName: project.name,
                title: AgentConversationRules.title(title),
                state: record.state,
                updatedAt: record.updatedAt,
                parentSessionID: AgentSessionLineage.load(session: session, state: state)?.parentSessionID,
            ))
        }
        return listed.reversed()
    }

    /// The project of the session the table does not know whose newest
    /// agent task is `taskID`, the task `stored` names it by.
    static func storedProject(
        of taskID: TaskID,
        table: AgentSessionTable,
        registry: TaskRegistry,
        home: String,
    ) async -> ResolvedProject? {
        guard let record = await registry.record(taskID), let session = sessionID(of: record),
              await table.entry(session) == nil,
              let sessions = CanonicalPath.resolve(DataFolder(home: home).sessions.path),
              let id = projectID(of: session, sessions: sessions)
        else { return nil }
        let superseded = await registry.records(kind: .agent).contains {
            sessionID(of: $0) == session && isNewer($0, than: record)
        }
        guard !superseded else { return nil }
        return try? AgentProjects.resolve(home: home, projectID: id, projectName: nil)
    }

    /// The session an agent task served: its worker's instance, a UUID.
    private static func sessionID(of record: TaskRegistry.Record) -> String? {
        guard record.kind == .agent, record.owner == .agent, let key = record.ownerKey, UUID(uuidString: key) != nil else {
            return nil
        }
        return key
    }

    /// Ordered by creation, which a record read back from disk keeps to the
    /// second; then by the length of its log, since a reopened session's task
    /// replays the whole history first; then by ID, so two answers agree.
    private static func isNewer(_ record: TaskRegistry.Record, than other: TaskRegistry.Record) -> Bool {
        (record.createdAt, record.lastSeq.rawValue, record.id.rawValue)
            > (other.createdAt, other.lastSeq.rawValue, other.id.rawValue)
    }

    /// The project id `sessions/<session>/session.json` names, read without
    /// following a link: the session's folder a real one, the file a
    /// regular one within `AgentProjects.readManifest`'s bound.
    private static func projectID(of session: String, sessions: String) -> String? {
        let folder = sessions + "/" + session
        var metadata = stat()
        guard lstat(folder, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              let file = try? AgentProjects.readManifest(folder + "/session.json"),
              let id = file["project"]?["id"]?.stringValue, !id.isEmpty
        else { return nil }
        return id
    }
}
