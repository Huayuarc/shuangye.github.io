import ApelinCore
import ApelinProtocol
import Foundation

/// The sidebar lists conversations by when the reader last started or wrote
/// in each (`SidebarOrder`): what an agent does never moves a row, a
/// message the reader sends does, and a conversation an agent opened keeps
/// the time it was taken in until the reader writes in it.
func checkSidebarOrder() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    func at(_ hours: Double) -> Date {
        today.addingTimeInterval(hours * 3600)
    }
    func sections(_ chats: [ChatSummary]) -> SidebarOrder.Sections {
        SidebarOrder.sections(of: chats, calendar: calendar)
    }
    func agentEvent(_ seq: UInt64, _ kind: String, at time: Date, _ values: [String: JSONValue] = [:]) -> TaskEvent {
        TaskEvent(seq: EventSeq(seq), kind: kind, time: time, payload: .object(values))
    }

    let task = TaskHandle(taskID: TaskID("build-task"), kind: .agent)
    var build = ChatRecord(
        summary: ChatSummary(title: "Build", lastInteraction: at(9), projectName: "Clock"),
        sessionID: UUID().uuidString.lowercased(),
        task: task,
    )
    var docs = ChatRecord(summary: ChatSummary(title: "Docs", lastInteraction: at(10), projectName: "Clock"))
    let plan = ChatSummary(title: "Plan", lastInteraction: at(-30), projectName: "Clock", isPinned: true)
    var notes = ChatRecord(summary: ChatSummary(title: "Notes", lastInteraction: at(-20), projectName: "Clock"))
    func listed() -> SidebarOrder.Sections {
        sections([build.summary, docs.summary, plan, notes.summary])
    }

    let start = listed()
    precondition(start.pinned == [plan.id], "the pinned one first")
    precondition(start.days == [
        SidebarOrder.Day(start: today, chats: [docs.summary.id, build.summary.id]),
        SidebarOrder.Day(start: at(-24), chats: [notes.summary.id]),
        SidebarOrder.Day(start: at(-48), chats: []),
    ], "the rest under their days, newest first, and the pinned one's day kept with no rows")
    precondition(SidebarOrder.newest([build.summary, docs.summary, plan, notes.summary])?.id == docs.summary.id)

    // Everything an agent writes, hours after the reader's message: a reply
    // streamed, a call, an approval asked and answered, a title, a
    // compaction, a message another conversation sent, the turn's end.
    let output = [
        agentEvent(1, "messageStarted", at: at(11)),
        agentEvent(2, "text", at: at(11), ["text": .string("Building")]),
        agentEvent(3, "toolCall", at: at(11), ["id": .string("t1"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        agentEvent(4, "approvalRequested", at: at(12), ["approvalID": .string("a1"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        agentEvent(5, TaskEvent.stateKind, at: at(12), ["state": .string(TaskState.waitingForApproval.rawValue)]),
        agentEvent(6, "approvalResolved", at: at(12), ["approvalID": .string("a1"), "decision": .string("approve")]),
        agentEvent(7, "toolResult", at: at(12), ["id": .string("t1"), "output": .string("ok")]),
        agentEvent(8, "message", at: at(12), ["text": .string("Built and installed.")]),
        agentEvent(9, "title", at: at(12), ["text": .string("Build the tweak")]),
        agentEvent(10, "compactionStarted", at: at(12)),
        agentEvent(11, "compactionFinished", at: at(12), ["outcome": .string("compacted")]),
        agentEvent(12, "prompt", at: at(13), ["text": .string("Review it"), "from": .string("other-session")]),
        agentEvent(13, "finished", at: at(13), ["reason": .string("completed")]),
    ]
    precondition(build.take(output) == output)
    // what the runtime does with a batch besides keeping its events
    build.summary.suggestTitle("Build the tweak")
    build.summary.isWorking = false
    precondition(build.summary.lastInteraction == at(9), "nothing the agent writes moves the conversation")
    precondition(listed() == start, "nor any row of the list")

    // A reopened session's task replays the whole history, newly timed.
    build.reopen(as: TaskHandle(taskID: TaskID("build-task-2"), kind: .agent))
    let replayed = output.map { TaskEvent(seq: $0.seq, kind: $0.kind, time: at(14), payload: $0.payload) }
    precondition(build.take(replayed).isEmpty && build.summary.lastInteraction == at(9) && listed() == start,
                 "and neither does the host replaying a reopened session")

    // The reader writes: the conversation moves up at once, before the host
    // has the message, and a message a running turn takes later moves it too.
    let message = ComposerDraft(text: "Now the lock screen")
    build.draft = message
    build.submit(message, at: at(15))
    precondition(build.sending?.map(\.id) == [message.id] && build.draft.text.isEmpty, "sent, shown and out of the composer")
    precondition(listed().days.first?.chats == [build.summary.id, docs.summary.id], "a message the reader sends moves it up")
    build.summary.isWorking = true
    docs.submit(ComposerDraft(text: "Fix the link"), at: at(16))
    precondition(listed().days.first?.chats == [docs.summary.id, build.summary.id], "another conversation written in goes above it")
    build.submit(ComposerDraft(text: "And the dock"), at: at(17))
    precondition(listed().days.first?.chats == [build.summary.id, docs.summary.id], "a queued one too")
    precondition(build.sending?.count == 2, "both shown until the host echoes them")

    // A message on a later day takes the conversation there; the day it
    // leaves goes with its last row, the pinned one's day stays.
    notes.submit(ComposerDraft(text: "Next steps"), at: at(30))
    precondition(listed().days == [
        SidebarOrder.Day(start: at(24), chats: [notes.summary.id]),
        SidebarOrder.Day(start: today, chats: [build.summary.id, docs.summary.id]),
        SidebarOrder.Day(start: at(-48), chats: []),
    ])

    // A conversation an agent opened is listed by when it was taken in,
    // whatever its agent writes after.
    let child = UUID().uuidString.lowercased()
    let opened: JSONValue = .object([
        "sessionID": .string(child),
        "task": .object(["taskID": .string("child-task"), "kind": .string("agent")]),
        "title": .string("Docs pass"),
        "prompt": .string("Write the README"),
    ])
    guard var adopted = ChatAdoption.record(opened: opened, parent: build, records: [build], now: at(18)) else {
        preconditionFailure("a conversation an agent opened is taken in")
    }
    precondition(adopted.summary.lastInteraction == at(18), "taken in now")
    let childOutput = [
        agentEvent(1, "prompt", at: at(18), ["text": .string("Write the README")]),
        agentEvent(2, "messageStarted", at: at(19)),
        agentEvent(3, "message", at: at(20), ["text": .string("Done.")]),
        agentEvent(4, "finished", at: at(20), ["reason": .string("completed")]),
    ]
    precondition(adopted.take(childOutput) == childOutput && adopted.summary.lastInteraction == at(18),
                 "its own first prompt and its agent's output leave it where it was taken in")
    let withChild = sections([build.summary, docs.summary, adopted.summary])
    precondition(withChild.days.first?.chats == [adopted.summary.id, build.summary.id, docs.summary.id])
    adopted.submit(ComposerDraft(text: "Add a changelog"), at: at(21))
    precondition(adopted.summary.lastInteraction == at(21), "until the reader writes in it")

    let missed = AgentSessionSummary(
        sessionID: UUID().uuidString.lowercased(),
        task: TaskHandle(taskID: TaskID("missed-task"), kind: .agent),
        state: .running,
        updatedAt: at(22),
        parentSessionID: build.sessionID,
    )
    let late = ChatAdoption.record(session: missed, records: [build], now: at(23))
    precondition(late?.summary.lastInteraction == at(23), "one adopted at launch by when it was taken in, not its last event")
    let linked = ChatAdoption.record(linked: missed, projectName: "Clock", records: [build], now: at(23))
    precondition(linked?.summary.lastInteraction == at(23), "and one a link named")

    // Two of the same moment keep one order however they were held.
    let first = ChatSummary(id: UUID(), title: "A", lastInteraction: at(5))
    let second = ChatSummary(id: UUID(), title: "B", lastInteraction: at(5))
    precondition(SidebarOrder.newestFirst([first, second]).map(\.id) == SidebarOrder.newestFirst([second, first]).map(\.id))

    // A conversation saved before keeps the time it has, under its old key.
    let saved = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","updated":10,"isPinned":false,"isWorking":false}"#.utf8)
    let older = try JSONDecoder().decode(ChatSummary.self, from: saved)
    precondition(older.lastInteraction == Date(timeIntervalSinceReferenceDate: 10), "an earlier file reads as it was")
    let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any]
    precondition(written?["updated"] as? Double == 10 && written?["lastInteraction"] == nil, "and is written under the same key")
    print("ok: the sidebar lists conversations by the reader's last message, never by the agent's output")
}
