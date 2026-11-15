import ApelinCore
import ApelinProtocol
import Foundation

/// The trace sheet lists each step as its kind over one line of its detail:
/// a thought's start, a call's reason (else what it runs or names, else its
/// result), an approval's decision; a step with nothing more opens nothing.
func checkTraceStep() {
    func json(_ values: [String: JSONValue]) -> String {
        String(decoding: (try? JSONCoding.encode(JSONValue.object(values))) ?? Data(), as: UTF8.self)
    }

    func call(_ title: String, _ detail: String) -> TraceStep {
        var message = ChatMessage(role: .tool, text: title)
        message.detail = detail
        return TraceStep(message)
    }

    let thought = TraceStep(ChatMessage(role: .thinking(seconds: 2, tools: 0), text: "\n  **Plan**\n\nRead the\theader first.  "))
    precondition(thought.title == String(localized: "Thoughts") && thought.hasDetail)
    precondition(thought.subtitle == "**Plan** Read the header first.",
                 "a thought's start on one line, each run of white space one space: \(thought.subtitle)")
    precondition(TraceStep.excerpt(String(repeating: "a", count: 200))
        == String(repeating: "a", count: TraceStep.excerptLength) + "…", "a long excerpt is cut at its length")
    let words = TraceStep.excerpt(String(repeating: "word ", count: 100))
    precondition(words.count <= TraceStep.excerptLength + 1 && words.hasSuffix("d…"),
                 "and never right after a space: \(words.suffix(8))")
    precondition(TraceStep.excerpt(String(repeating: "a", count: TraceStep.excerptLength)).count == TraceStep.excerptLength,
                 "an excerpt that fits is whole")
    let starting = TraceStep(ChatMessage(role: .thinking(seconds: nil, tools: 0), text: " \n"))
    precondition(starting.subtitle.isEmpty && !starting.hasDetail, "a thought with no text yet has nothing to open")

    let reasoned = call("Read README.md", json(["reason": .string("See how it builds"), "path": .string("README.md")]))
    precondition(reasoned.title == "Read README.md" && reasoned.subtitle == "See how it builds" && reasoned.hasDetail)
    let argv = call("Run a command", json(["argv": .array([.string("make"), .string("-C"), .string("My Tweak")])]))
    precondition(argv.subtitle == "make -C 'My Tweak'", "without a reason, the command line: \(argv.subtitle)")
    let shell = call("Run a command", json(["command": .string("ls\n  | wc -l"), "cwd": .string("Sources")]))
    precondition(shell.subtitle == "ls | wc -l", "shell text, on one line: \(shell.subtitle)")
    let repeated = call("Build it", json(["reason": .string("Build it"), "path": .string("Makefile")]))
    precondition(repeated.subtitle == "Makefile", "a reason that only repeats the title gives way: \(repeated.subtitle)")
    let finished = call("Restart SpringBoard", "{}\n\nRestarted.\nIt is back.")
    precondition(finished.subtitle == "Restarted. It is back." && finished.hasDetail, "else the result: \(finished.subtitle)")
    let other = call("Read the SDK", json(["framework": .string("UIKit")]))
    precondition(other.subtitle == "UIKit", "else what it was given first: \(other.subtitle)")
    let empty = call("Restart SpringBoard", "{}")
    precondition(empty.subtitle.isEmpty && !empty.hasDetail, "a call with nothing to show yet opens nothing")

    var pending = ChatMessage(role: .approval(nil), text: "Run a command\n\nBuild with make")
    precondition(TraceStep(pending).title == "Run a command" && TraceStep(pending).hasDetail)
    precondition(TraceStep(pending).subtitle == String(localized: "Approval Required"))
    pending.runsAsRoot = true
    precondition(TraceStep(pending).subtitle == String(localized: "Root Approval Required"))
    precondition(TraceStep(ChatMessage(role: .approval(.approve), text: "Install the package")).subtitle
        == String(localized: "Allowed Once"))
    let denied = TraceStep(ChatMessage(role: .approval(.deny), text: "Install the package"))
    precondition(denied.subtitle == String(localized: "Denied") && !denied.hasDetail, "an approval with no card text opens nothing")

    let events = [
        event(1, "prompt", ["text": .string("Make a change")]),
        event(2, "messageStarted"), event(3, "thinking", ["text": .string("Look first.")]),
        event(4, "toolCall", ["id": .string("t1"), "tool": .string("file_read"),
                              "arguments": .string(json(["reason": .string("Read the docs"), "path": .string("README.md")]))]),
        event(5, "toolResult", ["id": .string("t1"), "output": .string("# Demo")]),
        event(6, "approvalRequested", ["approvalID": .string("a1"), "tool": .string("shell_run"),
                                       "arguments": .string(json(["argv": .array([.string("make")])]))]),
        event(7, "approvalResolved", ["approvalID": .string("a1"), "decision": .string("approve")]),
        event(8, "message", ["text": .string("Done")]), event(9, "finished"),
    ]
    guard let summary = ChatTranscript(events: events, attachment: { _ in nil }).messages.first(where: { $0.role.isActivity })
    else { preconditionFailure("the turn has a summary") }
    let steps = TraceStep.messages(of: summary).map(TraceStep.init)
    precondition(steps.map(\.title) == [String(localized: "Thoughts"), "Read README.md", "Run a command"],
                 "one row per step, in order: \(steps.map(\.title))")
    precondition(steps.map(\.subtitle) == ["Look first.", "Read the docs", String(localized: "Allowed Once")],
                 "\(steps.map(\.subtitle))")
    precondition(steps.allSatisfy(\.hasDetail))

    var standIn = ChatMessage(role: .thinking(seconds: nil, tools: 0), text: "")
    precondition(TraceStep.messages(of: standIn).map(\.id) == [standIn.id], "a summary with no steps yet lists itself")
    let step = ChatMessage(role: .tool, text: "List files")
    standIn.trace = [step, step, ChatMessage(role: .tool, text: "Search files")]
    precondition(TraceStep.messages(of: standIn).map(\.text) == ["List files", "Search files"], "each id once")
    print("ok: the trace lists each step by its kind over a line of its detail, and opens only what has more")
}
