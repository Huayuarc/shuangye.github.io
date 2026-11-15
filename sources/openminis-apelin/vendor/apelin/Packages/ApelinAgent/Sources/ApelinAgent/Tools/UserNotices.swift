import enum ApelinProtocol.AgentNoticeRules
import Foundation
import KWWKAI

/// `apelin_notification_send`'s rules on the agent's side: the notice as the host will
/// post it, and how many this turn may still send. The session host
/// decides again from the `notice` event (`AgentNoticeTrack`); these are
/// checked first so the model hears why one was not sent, rather than
/// believing the user was told.
struct UserNotices {
    private var sentThisTurn = 0
    private var lastSent: Date?

    /// The notice to record, plain and within the lengths, or why not.
    /// Counted as sent once it passes, before it is recorded.
    mutating func take(_ arguments: JSONValue, now: Date) throws -> (title: String?, body: String) {
        guard let body = try AgentNoticeRules.plain(arguments.requireString("body")) else {
            throw ToolArgumentError("body is empty: say in a sentence what happened or what the user must do")
        }
        guard body.count <= AgentNoticeRules.maximumBodyLength else {
            throw ToolArgumentError("body is \(body.count) characters; keep it to \(AgentNoticeRules.maximumBodyLength), one or two plain sentences")
        }
        let title = AgentNoticeRules.plain(arguments.argString("title"))
        if let title, title.count > AgentNoticeRules.maximumTitleLength {
            throw ToolArgumentError("title is \(title.count) characters; keep it to \(AgentNoticeRules.maximumTitleLength), a few words, or leave it out")
        }
        guard sentThisTurn < AgentNoticeRules.maximumPerTurn else {
            throw ToolDeniedError(message: "Not sent: this turn has sent \(AgentNoticeRules.maximumPerTurn) notifications, the most one may. Say the rest in your reply; Apelin notifies the user when the turn ends.")
        }
        if let lastSent, now.timeIntervalSince(lastSent) < AgentNoticeRules.minimumInterval {
            let seconds = Int(AgentNoticeRules.minimumInterval)
            throw ToolDeniedError(message: "Not sent: the last notification went less than \(seconds) seconds ago, and they must be at least \(seconds) seconds apart. Fold this into the next one, or into your reply.")
        }
        sentThisTurn += 1
        lastSent = now
        return (title, body)
    }

    /// A new turn may send its own few.
    mutating func turnEnded() {
        sentThisTurn = 0
    }

    /// What the model reads once the notice is recorded.
    var sentMessage: String {
        let left = AgentNoticeRules.maximumPerTurn - sentThisTurn
        return "Sent to Apelin as a notification. It shows only while Apelin is not in front and the user allows its notifications, and nothing tells you whether they saw it. \(left) more may go this turn."
    }
}
