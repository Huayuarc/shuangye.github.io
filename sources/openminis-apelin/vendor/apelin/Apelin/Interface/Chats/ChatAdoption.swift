import ApelinCore
import ApelinProtocol
import Foundation

/// Conversations an agent opened (`AgentConversations`), taken in as the
/// app's own: listed in the project it was opened in — the opener's, or
/// another one the opener named, General Chat's included —, followed like
/// any other, and never selected on their own. Each is listed by `now`, the
/// time it was taken in, until the reader writes in it
/// (`ChatSummary.lastInteraction`): never by when its agent last wrote.
enum ChatAdoption {
    /// The record for a `conversationOpened` event on `parent`'s task, or
    /// nil when a record already has that session or the event names none.
    /// Its project is the one the event names, else the opener's.
    static func record(
        opened payload: JSONValue?,
        parent: ChatRecord,
        records: [ChatRecord],
        now: Date = Date(),
    ) -> ChatRecord? {
        guard let project = payload?["projectName"]?.stringValue ?? parent.summary.projectName,
              let sessionID = payload?["sessionID"]?.stringValue, UUID(uuidString: sessionID) != nil,
              let task = try? payload?["task"]?.decode(TaskHandle.self), task.kind == .agent,
              !records.contains(where: { $0.sessionID == sessionID })
        else { return nil }
        let title = title(payload?["title"]?.stringValue, prompt: payload?["prompt"]?.stringValue)
        return ChatRecord(
            summary: ChatSummary(title: title, lastInteraction: now, projectName: project, isWorking: true),
            sessionID: sessionID,
            task: task,
        )
    }

    /// The record for a running session an agent opened while the app was
    /// not following its opener, or nil when it has one already, has ended,
    /// or its opener has no record. Its project is the one the host lists
    /// it in, else the opener's.
    static func record(session: AgentSessionSummary, records: [ChatRecord], now: Date = Date()) -> ChatRecord? {
        guard let parentID = session.parentSessionID, !session.state.isTerminal,
              !records.contains(where: { $0.sessionID == session.sessionID }),
              let parent = records.first(where: { $0.sessionID == parentID }),
              let project = session.projectName ?? parent.summary.projectName
        else { return nil }
        return ChatRecord(
            summary: ChatSummary(
                title: title(session.title, prompt: nil),
                lastInteraction: now,
                projectName: project,
            ),
            sessionID: session.sessionID,
            task: session.task,
        )
    }

    /// The record for a session an `apelin://conversation/` link names that
    /// has no opener to take the project from, in `projectName`, the
    /// project the host names for it; nil when a record has it already.
    /// Ended or not: the link asked for it, and its log still reads.
    static func record(
        linked session: AgentSessionSummary,
        projectName: String,
        records: [ChatRecord],
        now: Date = Date(),
    ) -> ChatRecord? {
        guard !records.contains(where: { $0.sessionID == session.sessionID }) else { return nil }
        return ChatRecord(
            summary: ChatSummary(
                title: title(session.title, prompt: nil),
                lastInteraction: now,
                projectName: projectName,
                isWorking: !session.state.isTerminal,
            ),
            sessionID: session.sessionID,
            task: session.task,
        )
    }

    /// The opener's title, else the first line of the prompt, as the
    /// sidebar shows a conversation the user started; empty, untitled,
    /// when there is neither.
    static func title(_ title: String?, prompt: String?) -> String {
        for text in [title, prompt] {
            let line = text?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(80))
            }
        }
        return ""
    }
}
