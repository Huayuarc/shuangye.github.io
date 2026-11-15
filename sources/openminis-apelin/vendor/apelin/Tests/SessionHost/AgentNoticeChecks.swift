import ApelinCore
import ApelinProtocol
import Foundation

// The session host's banners (Apelind/Session/Notice/AgentNotices.swift):
// which agent events post one, what it says, its identifiers, the excerpt,
// and that a session opened again does not announce its old turns.

private func object(_ fields: [String: JSONValue]) -> JSONValue {
    .object(fields)
}

private final class Posted: @unchecked Sendable {
    private let lock = NSLock()
    private var notices: [AgentNotice] = []

    func append(_ notice: AgentNotice) {
        lock.withLock { notices.append(notice) }
    }

    var all: [AgentNotice] {
        lock.withLock { notices }
    }
}

func agentNoticeChecks() async {
    let session = "0b9d3c1e-6a64-4c2f-9d3e-2f1a7c5b8e10"

    // MARK: The excerpt

    check(AgentNoticeText.excerpt("Done. The tweak builds.\n\nMore below.") == "Done. The tweak builds.", "an excerpt is the first paragraph")
    check(
        AgentNoticeText.excerpt("## Summary\n\nThe **tweak** hides the `dock`, see [the log](https://example.com/log).") == "The tweak hides the dock, see the log.",
        "headings are passed over, emphasis, code marks and link targets taken off",
    )
    check(AgentNoticeText.excerpt("```swift\nlet x = 1\n```\nIt compiles.") == "It compiles.", "a leading code block is passed over")
    check(AgentNoticeText.excerpt("It compiles:\n```\nok\n```\nand runs.") == "It compiles:", "a code block ends the paragraph")
    check(AgentNoticeText.excerpt("- Built it\n- [x] Installed *it*") == "Built it Installed it", "list and task markers go, single-star emphasis too")
    check(AgentNoticeText.excerpt("> Quoted\nline") == "Quoted line", "a quote's marker goes and its lines join")
    check(AgentNoticeText.excerpt("snake_case_name stays") == "snake_case_name stays", "underscores inside words stay")
    check(AgentNoticeText.excerpt("```\nonly code\n```") == nil, "a message of code alone has no excerpt")
    check(AgentNoticeText.excerpt("  \n\n---\n| a | b |\n") == nil, "nor one of rules and tables")
    let long = String(repeating: "word ", count: 60)
    let cut = AgentNoticeText.excerpt(long) ?? ""
    check(cut.count <= AgentNoticeText.excerptLength && cut.hasSuffix("word…"), "a long paragraph is cut at a word: \(cut)")
    let unbroken = String(repeating: "x", count: 400)
    check(AgentNoticeText.excerpt(unbroken)?.count == AgentNoticeText.excerptLength, "an unbroken one is cut at the limit")
    check(AgentNoticeText.reason(arguments: #"{"path":"a","reason":" Check the hook "}"#) == "Check the hook", "a call's reason is read from its arguments")
    check(AgentNoticeText.reason(arguments: #"{"path":"a"}"#) == nil && AgentNoticeText.reason(arguments: "not json") == nil, "a call without one has none")

    // MARK: Which events post, and what they say

    var track = AgentNoticeTrack(sessionID: session)
    let none = AgentNoticeMarks()
    _ = track.take("prompt", payload: object(["id": .string("m"), "text": .string("Hide the dock\nplease")]), title: nil, posted: none)
    _ = track.take("toolCall", payload: object([
        "id": .string("call-1"),
        "tool": .string("apelin_project_build"),
        "arguments": .string(#"{"reason":"Build the tweak to check it compiles"}"#),
    ]), title: nil, posted: none)
    let approval = track.take("approvalRequested", payload: object([
        "approvalID": .string("a-1"),
        "toolCallID": .string("call-1"),
        "tool": .string("apelin_project_build"),
        "reason": .string("The build description changed. Review it before running."),
    ]), title: nil, posted: none)
    check(
        approval == AgentNotice(
            identifier: "\(session).approval.1",
            sessionID: session,
            title: .verbatim("Hide the dock"),
            subtitle: .key("Approval Required"),
            body: .verbatim("Build the tweak to check it compiles"),
        ),
        "an approval is named by the first message until the session has a title, and says the call's reason: \(String(describing: approval))",
    )
    check(approval?.link == "apelin://conversation/\(session)", "a tap opens the conversation")
    _ = track.take("message", payload: object(["text": .string("I will build it.")]), title: nil, posted: none)
    _ = track.take("message", payload: object(["text": .string("```\nlog\n```")]), title: nil, posted: none)
    let finished = track.take("finished", payload: object(["reason": .string("completed")]), title: "Dock Hider", posted: none)
    check(
        finished == AgentNotice(
            identifier: "\(session).turn.1",
            sessionID: session,
            title: .verbatim("Dock Hider"),
            body: .verbatim("I will build it."),
        ),
        "a completed turn says its last message with text, under the session's title: \(String(describing: finished))",
    )

    let quiet = track.take("finished", payload: object(["reason": .string("completed")]), title: "Dock Hider", posted: none)
    check(quiet?.body == .key("Done") && quiet?.identifier == "\(session).turn.2", "a turn that wrote nothing says Done")
    let stopped = track.take("finished", payload: object(["reason": .string("aborted")]), title: "Dock Hider", posted: none)
    check(stopped == nil && track.marks.turns == 3, "a turn the reader stopped posts nothing, and still counts")
    _ = track.take("error", payload: object(["message": .string("The model provider returned an error. Try again.")]), title: nil, posted: none)
    let failed = track.take("finished", payload: object(["reason": .string("failed")]), title: nil, posted: none)
    check(
        failed?.subtitle == .key("Failed") && failed?.body == .verbatim("The model provider returned an error. Try again."),
        "a failed turn says its error",
    )
    let gate = track.take("approvalRequested", payload: object([
        "approvalID": .string("a-2"),
        "toolCallID": .string("call-1"),
        "reason": .string("This command is not in your approved presets. Review it before running."),
    ]), title: nil, posted: none)
    check(
        gate?.body == .verbatim("This command is not in your approved presets. Review it before running.")
            && gate?.identifier == "\(session).approval.2",
        "a call whose reason is gone with its turn says why the gate asked",
    )

    var untitled = AgentNoticeTrack(sessionID: session)
    let bare = untitled.take("approvalRequested", payload: object(["approvalID": .string("a")]), title: nil, posted: none)
    check(bare?.title == .key("New Chat") && bare?.body == nil, "a session with no title and no message is a New Chat")

    var headless = AgentNoticeTrack(sessionID: session, headless: true)
    let console = headless.take("finished", payload: object(["reason": .string("completed")]), title: nil, posted: none)
    let consoleApproval = headless.take("approvalRequested", payload: object(["approvalID": .string("a")]), title: nil, posted: none)
    check(console == nil && consoleApproval == nil && headless.marks == AgentNoticeMarks(turns: 1, approvals: 1), "a headless session posts nothing")

    // MARK: The agent's own notices (apelin_notification_send)

    check(AgentNoticeRules.plain("  Build\n\tfailed:\u{202E}  see\u{0007} log ") == "Build failed: see log", "a notice is one plain line")
    check(AgentNoticeRules.plain(" \n\u{200F} ") == nil && AgentNoticeRules.plain(nil) == nil, "nothing left is no notice")
    let wordy = AgentNoticeRules.bounded(String(repeating: "word ", count: 60), limit: AgentNoticeRules.maximumBodyLength) ?? ""
    check(wordy.count <= AgentNoticeRules.maximumBodyLength && wordy.hasSuffix("word…"), "a long notice is cut at a word: \(wordy)")
    check(AgentNoticeRules.bounded("Short.", limit: 40) == "Short.", "a short one stays as it is")

    var notifying = AgentNoticeTrack(sessionID: session)
    _ = notifying.take("prompt", payload: object(["text": .string("Set up the toolchain")]), title: nil, posted: none)
    let notice = notifying.take("notice", payload: object([
        "title": .string("Toolchain ready"),
        "body": .string("CLT 16.4 is set up.\nUnlock the phone so I can test it."),
    ]), title: "Toolchain", posted: none)
    check(
        notice == AgentNotice(
            identifier: "\(session).notice.1",
            sessionID: session,
            title: .verbatim("Toolchain"),
            subtitle: .verbatim("Toolchain ready"),
            body: .verbatim("CLT 16.4 is set up. Unlock the phone so I can test it."),
        ),
        "a notice is headed by the conversation, its title the subtitle, its body one plain line: \(String(describing: notice))",
    )
    check(notice?.link == "apelin://conversation/\(session)", "a notice's tap opens the conversation")
    let untitledNotice = notifying.take("notice", payload: object(["body": .string(String(repeating: "x", count: 400))]), title: nil, posted: none)
    check(
        untitledNotice?.subtitle == nil && untitledNotice?.title == .verbatim("Set up the toolchain")
            && untitledNotice?.body == .verbatim(String(repeating: "x", count: AgentNoticeRules.maximumBodyLength - 1) + "…"),
        "one without a title has no subtitle, and a body past the limit is cut",
    )
    let blank = notifying.take("notice", payload: object(["body": .string(" \n ")]), title: nil, posted: none)
    let fourth = notifying.take("notice", payload: object(["body": .string("One too many.")]), title: nil, posted: none)
    check(blank == nil && fourth == nil && notifying.marks.notices == 4, "an empty notice and one past the turn's \(AgentNoticeRules.maximumPerTurn) post nothing, and still count")
    _ = notifying.take("prompt", payload: object(["text": .string("Go on")]), title: nil, posted: none)
    let afterPrompt = notifying.take("notice", payload: object(["body": .string("Built.")]), title: nil, posted: none)
    check(afterPrompt?.identifier == "\(session).notice.5", "a prompt starts the count again")
    for _ in 1 ..< AgentNoticeRules.maximumPerTurn {
        _ = notifying.take("notice", payload: object(["body": .string("More.")]), title: nil, posted: none)
    }
    _ = notifying.take("finished", payload: object(["reason": .string("completed")]), title: nil, posted: none)
    let afterTurn = notifying.take("notice", payload: object(["body": .string("Installed.")]), title: nil, posted: none)
    check(afterTurn?.identifier == "\(session).notice.\(5 + AgentNoticeRules.maximumPerTurn)", "so does a turn's end")
    let counted = notifying.take(
        "notice",
        payload: object(["body": .string("Seen.")]),
        title: nil,
        posted: AgentNoticeMarks(notices: 100),
    )
    check(counted == nil, "a notice the marks already count posts nothing")
    var headlessNotices = AgentNoticeTrack(sessionID: session, headless: true)
    check(
        headlessNotices.take("notice", payload: object(["body": .string("Done.")]), title: nil, posted: none) == nil
            && headlessNotices.marks.notices == 1,
        "a headless session posts no notice",
    )
    let older = try? JSONDecoder().decode(AgentNoticeMarks.self, from: Data(#"{"turns":2,"approvals":1}"#.utf8))
    check(older == AgentNoticeMarks(turns: 2, approvals: 1, notices: 0), "marks saved before notices still read: \(String(describing: older))")

    // MARK: A session opened again does not announce its old turns

    let folder = scratch.appendingPathComponent("notices")
    let sessions = folder.appendingPathComponent("sessions")
    try? FileManager.default.createDirectory(at: sessions.appendingPathComponent(session), withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("notices.json")
    let posted = Posted()
    func record(_ task: TaskID, session owner: String? = nil) -> TaskRegistry.Record {
        TaskRegistry.Record(
            id: task,
            kind: .agent,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            lastSeq: .start,
            owner: .agent,
            ownerKey: owner ?? session,
            cancelRequested: false,
        )
    }
    let turn: [(String, JSONValue?)] = [
        ("prompt", object(["text": .string("Hide the dock")])),
        ("message", object(["text": .string("Built.")])),
        ("finished", object(["reason": .string("completed")])),
    ]

    let first = TaskID.make()
    var notices = AgentNotices(file: file, sessions: sessions) { posted.append($0) }
    await notices.opened(session: session, task: first, headless: false)
    for (kind, payload) in turn {
        await notices.relayed(record(first), kind: kind, payload: payload)
    }
    check(posted.all.map(\.identifier) == ["\(session).turn.1"], "a live turn posts once: \(posted.all.map(\.identifier))")

    // The host restarted: the app opens the session again and its worker
    // relays the whole log into a new task, then a new turn.
    let second = TaskID.make()
    notices = AgentNotices(file: file, sessions: sessions) { posted.append($0) }
    await notices.opened(session: session, task: second, headless: false)
    for (kind, payload) in turn + [("prompt", object(["text": .string("Again")])), ("finished", object(["reason": .string("completed")]))] {
        await notices.relayed(record(second), kind: kind, payload: payload)
    }
    check(
        posted.all.map(\.identifier) == ["\(session).turn.1", "\(session).turn.2"],
        "the replayed turn posts nothing, the new one does: \(posted.all.map(\.identifier))",
    )
    check(posted.all.last?.body == .key("Done"), "a turn's message is its own, not the replayed one's")

    let third = TaskID.make()
    await notices.opened(session: session, task: third, headless: true)
    await notices.relayed(record(third), kind: "finished", payload: object(["reason": .string("completed")]))
    await notices.relayed(record(third), kind: "finished", payload: object(["reason": .string("completed")]))
    await notices.relayed(record(third), kind: "finished", payload: object(["reason": .string("completed")]))
    check(posted.all.count == 2, "a headless task posts nothing")

    func saved() -> [String: AgentNoticeMarks]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: AgentNoticeMarks].self, from: $0) }
    }
    check(saved()?[session] == AgentNoticeMarks(turns: 3, approvals: 0), "the marks are on disk: \(String(describing: saved()))")

    // A session whose event log is gone cannot be relayed again: its marks
    // go when they load, and with the next save.
    try? FileManager.default.removeItem(at: sessions.appendingPathComponent(session))
    let other = "5f0c2a8e-1d3b-4e6f-8a9c-7b2d4e6f8a1c"
    try? FileManager.default.createDirectory(at: sessions.appendingPathComponent(other), withIntermediateDirectories: true)
    let pruned = AgentNotices(file: file, sessions: sessions) { posted.append($0) }
    await pruned.relayed(record(TaskID.make(), session: other), kind: "finished", payload: object(["reason": .string("completed")]))
    check(
        saved()?[session] == nil && saved()?[other] == AgentNoticeMarks(turns: 1, approvals: 0) && posted.all.count == 3,
        "a gone session's marks are dropped: \(String(describing: saved()))",
    )

    // A notice the agent sent is not sent again when the session reopens.
    let notifier = "9a7e3b1c-2d4f-4a6b-8c0e-1f3a5b7d9e2c"
    try? FileManager.default.createDirectory(at: sessions.appendingPathComponent(notifier), withIntermediateDirectories: true)
    let sent = Posted()
    let noticeTurn: [(String, JSONValue?)] = [
        ("prompt", object(["text": .string("Build and install it")])),
        ("notice", object(["body": .string("The build failed: a header is missing.")])),
        ("finished", object(["reason": .string("completed")])),
    ]
    let live = TaskID.make()
    var notifierNotices = AgentNotices(file: file, sessions: sessions) { sent.append($0) }
    await notifierNotices.opened(session: notifier, task: live, headless: false)
    for (kind, payload) in noticeTurn {
        await notifierNotices.relayed(record(live, session: notifier), kind: kind, payload: payload)
    }
    let reopened = TaskID.make()
    notifierNotices = AgentNotices(file: file, sessions: sessions) { sent.append($0) }
    await notifierNotices.opened(session: notifier, task: reopened, headless: false)
    for (kind, payload) in noticeTurn + [("prompt", object(["text": .string("Again")])), ("notice", object(["body": .string("Installed.")]))] {
        await notifierNotices.relayed(record(reopened, session: notifier), kind: kind, payload: payload)
    }
    check(
        sent.all.map(\.identifier) == ["\(notifier).notice.1", "\(notifier).turn.1", "\(notifier).notice.2"],
        "the replayed notice posts nothing, the new one does: \(sent.all.map(\.identifier))",
    )
    check(saved()?[notifier] == AgentNoticeMarks(turns: 1, approvals: 0, notices: 2), "a session's notices are on disk: \(String(describing: saved()))")
}
