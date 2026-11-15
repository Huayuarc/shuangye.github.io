import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation

/// What apelin_conversation_read makes of another conversation's task events:
/// its state over the whole log, the approvals still waiting, and the
/// assistant's messages after `afterSeq`, bounded.
struct ConversationReader {
    let afterSeq: UInt64
    let byteLimit: Int
    private(set) var lastSeq = EventSeq.start
    private var taskState = TaskState.running
    private var finishedAfter = false
    private var askedAfter = false
    /// The latest turn event: `prompt`, `steer` and `messageStarted` start
    /// one, `finished` ends it.
    private var turnEnded: Bool?
    private var pending: [ConversationApproval] = []
    private var messages: [ConversationMessage] = []
    private var bytes = 0
    private(set) var truncated = false
    /// Where the next read goes on from once the messages were cut.
    private var resumeSeq: UInt64?

    init(afterSeq: UInt64, byteLimit: Int) {
        self.afterSeq = afterSeq
        self.byteLimit = byteLimit
    }

    mutating func take(_ batch: TaskEventBatch) {
        for event in batch.events where event.seq > lastSeq {
            take(event)
            lastSeq = event.seq
        }
        // The task's state when the batch was read, which the log reaches
        // once it is read to the end.
        taskState = batch.state
    }

    private mutating func take(_ event: TaskEvent) {
        let seq = event.seq.rawValue
        let payload = event.payload
        switch event.kind {
        case "prompt", "steer", "messageStarted":
            turnEnded = false
        case "finished":
            turnEnded = true
            if seq > afterSeq {
                finishedAfter = true
            }
        case "approvalRequested":
            if let id = payload?["approvalID"]?.stringValue {
                pending.append(ConversationApproval(
                    approvalID: id,
                    tool: Self.currentName(payload?["tool"]?.stringValue ?? ""),
                    reason: payload?["reason"]?.stringValue ?? "",
                ))
                if seq > afterSeq {
                    askedAfter = true
                }
            }
        case "approvalResolved":
            let id = payload?["approvalID"]?.stringValue
            pending.removeAll { $0.approvalID == id }
        case "message", "error":
            let text = (event.kind == "message" ? payload?["text"] : payload?["message"])?.stringValue ?? ""
            guard seq > afterSeq, !text.isEmpty, !truncated else { break }
            add(ConversationMessage(seq: seq, role: event.kind == "message" ? "assistant" : "error", text: text))
        case TaskEvent.stateKind:
            if let name = payload?["state"]?.stringValue, let state = TaskState(rawValue: name) {
                taskState = state
            }
        default:
            break
        }
    }

    /// Whole messages while they fit; the first that does not is cut, the
    /// rest left for the next read.
    private mutating func add(_ message: ConversationMessage) {
        let size = message.text.utf8.count
        if bytes + size <= byteLimit {
            messages.append(message)
            bytes += size
            return
        }
        truncated = true
        if messages.isEmpty {
            var cut = message
            cut.text = String(decoding: Data(message.text.utf8).prefix(byteLimit), as: UTF8.self)
                + "\n… (cut at \(byteLimit / 1024) KiB)"
            messages.append(cut)
            resumeSeq = message.seq
        } else {
            resumeSeq = messages.last?.seq
        }
    }

    var state: ConversationState {
        if taskState.isTerminal {
            return .ended
        }
        if !pending.isEmpty || taskState == .waitingForApproval {
            return .waitingForApproval
        }
        return turnEnded == true ? .idle : .running
    }

    /// Nothing more to wait for: it ended, it asked for an approval after
    /// `afterSeq`, it finished a turn after `afterSeq`, or the messages
    /// were cut and the rest is for the next read.
    var isSettled: Bool {
        switch state {
        case .ended: true
        case .waitingForApproval: askedAfter || truncated
        case .idle: finishedAfter || truncated
        case .running: truncated
        }
    }

    /// An ended conversation waits on nothing: an approval it asked for
    /// before its task ended can no longer be given.
    func response(sessionID: String, title: String?, timedOut: Bool) -> ConversationReadToolResponse {
        ConversationReadToolResponse(
            sessionID: sessionID,
            title: title,
            state: state,
            messages: messages,
            pendingApprovals: state == .ended ? [] : pending,
            lastSeq: resumeSeq ?? max(lastSeq.rawValue, afterSeq),
            truncated: truncated,
            timedOut: timedOut,
        )
    }

    /// A tool by today's name, for a conversation recorded under an earlier
    /// release's: the model calls the tools it has.
    private static func currentName(_ tool: String) -> String {
        AgentToolName.canonical(tool)?.rawValue ?? tool
    }
}
