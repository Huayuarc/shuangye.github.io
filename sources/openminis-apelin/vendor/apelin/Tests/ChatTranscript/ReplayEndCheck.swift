import ApelinCore
import ApelinProtocol
import Foundation

/// A reopened session's task that ends before its replay has caught up (its
/// worker died, the host stopped, a second open of the session failed) ends
/// the turn on its last `state`, as a first task does. A conversation an
/// earlier version saved, which read that `state` as part of the replay and
/// moved its cursor past it, takes it again once an attach says the task
/// has finished, and only once.
func checkReplayEnd() {
    let askedID = UUID()
    // A turn the conversation saw start and not end: its task stopped while
    // the app was away. The new task replays it, numbered as it was.
    let history = [
        event(1, "prompt", ["id": .string(askedID.uuidString), "text": .string("Build it")]),
        event(2, "messageStarted"), event(3, "thinking", ["text": .string("Reading the project")]),
        event(4, "approvalRequested", ["approvalID": .string("a1"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        event(5, TaskEvent.stateKind, ["state": .string(TaskState.waitingForApproval.rawValue)]),
        event(6, "approvalResolved", ["approvalID": .string("a1"), "decision": .string("approve")]),
        event(7, TaskEvent.stateKind, ["state": .string(TaskState.running.rawValue)]),
        event(8, "text", ["text": .string("Building")]),
    ]
    let replay = history
    let shown = ChatTranscript(events: history) { _ in nil }
    precondition(shown.isWorking, "the turn it saw start still runs")

    func reopened() -> ChatRecord {
        var record = ChatRecord(summary: ChatSummary(title: "Build", lastInteraction: Date(), isWorking: true))
        record.task = TaskHandle(taskID: .make(), kind: .agent)
        record.events = history
        record.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
        return record
    }

    func end(_ seq: Int, _ state: TaskState) -> TaskEvent {
        event(UInt64(seq), TaskEvent.stateKind, [
            "state": .string(state.rawValue), "message": .string("The background process for this task stopped."),
        ])
    }

    func finished(_ record: ChatRecord, _ state: TaskState, at end: TaskEvent, carrying events: [TaskEvent]) -> TaskEventBatch {
        TaskEventBatch(taskID: record.task!.taskID, events: events, state: state, lastSeq: end.seq, finished: true)
    }

    // The task ends after so much of the replay: none of it (a second open
    // failed), part of it, or all of it, with the end in the same batch or
    // in one of its own.
    let cuts: [(state: TaskState, replayed: Int, inOneBatch: Bool)] = [
        (.failed, 0, true), (.interrupted, 3, true), (.interrupted, 5, false),
        (.failed, replay.count, false), (.cancelled, replay.count, true), (.cancelled, 7, false),
    ]
    for cut in cuts {
        var record = reopened()
        let ending = end(cut.replayed + 1, cut.state)
        let read = Array(replay.prefix(cut.replayed))
        let taken = cut.inOneBatch ? record.take(read + [ending]) : record.take(read) + record.take([ending])
        precondition(taken == [ending], "a task that ends \(cut.state) during its replay is taken at its end")
        precondition(record.events == history + [ending] && record.replay == nil && record.cursor == ending.seq,
                     "that one event, which ends the replay")
        let ended = ChatTranscript(events: record.events) { _ in nil }
        precondition(!ended.isWorking && !ended.isCompacting, "and the turn ends, as it does in a first task")
        precondition(ended.messages.map(\.id) == shown.messages.map(\.id), "on the rows it showed, none added or lost")
        precondition(record.missedEnd(of: finished(record, cut.state, at: ending, carrying: [ending]), isWorking: ended.isWorking) == nil,
                     "and an attach that says the task finished finds nothing missing")
    }

    // The states an approval sets are part of the replay, read past with the
    // rest of it; the first message it has not seen ends it, as before.
    var replayed = reopened()
    precondition(replayed.take(Array(replay.prefix(5))).isEmpty && replayed.take(Array(replay.dropFirst(5))).isEmpty,
                 "waitingForApproval and running are read past")
    precondition(replayed.events == history && replayed.cursor == replay.last?.seq)
    let next = event(UInt64(replay.count + 1), "prompt", ["id": .string(UUID().uuidString), "text": .string("And test it")])
    precondition(replayed.take([next]) == [next] && replayed.replay == nil, "a new message ends the replay")
    let goingOn = ChatTranscript(events: replayed.events) { _ in nil }.messages
    precondition(Array(goingOn.prefix(shown.messages.count)).map(\.id) == shown.messages.map(\.id),
                 "and the rows before it stay as they were")

    // A conversation an earlier version saved: it read the task's end as
    // part of the replay, which still waits, and its cursor is past it.
    var swallowed = reopened()
    let lost = end(replay.count + 1, .interrupted)
    precondition(swallowed.take(replay).isEmpty)
    swallowed.replay?.cursor = lost.seq
    let atEnd = finished(swallowed, .interrupted, at: lost, carrying: [])
    precondition(swallowed.take(atEnd.events).isEmpty, "an attach past the cursor brings nothing")
    var cache = ChatTranscriptCache()
    func cached(_ record: ChatRecord) -> ChatTranscript {
        cache.transcript(of: record, now: Date(), isFollowed: { _ in true }, conversationTitle: { _ in nil }) { _ in nil }
    }
    let stuck = cached(swallowed)
    precondition(stuck.isWorking && stuck.messages.count == shown.messages.count + 1 && stuck.messages.last?.role.isThinking == true,
                 "so the turn runs on, a running summary standing in under its reply")
    precondition(swallowed.missedEnd(of: atEnd, isWorking: stuck.isWorking) == lost.seq,
                 "until an attach says the task finished: its end is its last event")
    let running = TaskEventBatch(taskID: atEnd.taskID, events: [], state: .running, lastSeq: lost.seq, finished: false)
    precondition(swallowed.missedEnd(of: running, isWorking: true) == nil, "a task still running has no end to miss")
    let empty = TaskEventBatch(taskID: atEnd.taskID, events: [], state: .failed, lastSeq: .start, finished: true)
    precondition(swallowed.missedEnd(of: empty, isWorking: true) == nil, "nor one with no events")
    let ahead = finished(swallowed, .interrupted, at: end(replay.count + 2, .interrupted), carrying: [])
    precondition(swallowed.missedEnd(of: ahead, isWorking: true) == nil, "and an end the cursor has not reached is not missed")

    var refused = swallowed
    precondition(!refused.takeMissedEnd(event(lost.seq.rawValue, TaskEvent.stateKind, ["state": .string("running")]), at: lost.seq),
                 "only a state that ends the task is taken")
    precondition(!refused.takeMissedEnd(end(replay.count, .interrupted), at: lost.seq), "and only at the task's last event")
    precondition(!refused.takeMissedEnd(nil, at: lost.seq), "an end that could not be read again is not made up")
    precondition(refused.events == history && refused.replay != nil, "none of them adds an event")
    precondition(!refused.summary.isWorking, "but the row stops working all the same: the task has ended")

    precondition(swallowed.takeMissedEnd(lost, at: lost.seq), "the end read again is taken")
    precondition(swallowed.events == history + [lost] && swallowed.replay == nil && swallowed.cursor == lost.seq,
                 "that one event, which ends the replay")
    let converged = cached(swallowed)
    precondition(!converged.isWorking && !swallowed.summary.isWorking, "and the turn ends")
    precondition(converged.messages.map(\.id) == shown.messages.map(\.id), "on the rows it showed, the stand-in gone")
    precondition(converged.messages == ChatTranscript(events: swallowed.events) { _ in nil }.messages,
                 "the runtime's transcript reads it as one built from every event does")
    precondition(swallowed.take(atEnd.events).isEmpty)
    precondition(swallowed.missedEnd(of: atEnd, isWorking: converged.isWorking) == nil,
                 "a second attach that says the task finished finds nothing missing")
    precondition(!swallowed.takeMissedEnd(lost, at: lost.seq) && swallowed.events.count == history.count + 1,
                 "and the end is taken once")
    print("ok: a reopened session's task that ends during its replay ends the turn, and one read past is taken again once")
}
