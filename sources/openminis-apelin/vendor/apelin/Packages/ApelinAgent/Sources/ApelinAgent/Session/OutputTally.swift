import ApelinProtocol
import Foundation

/// The output tokens a run has received, for the app's counter (`received`):
/// what has streamed of the message in progress — text, thinking and a
/// tool call's arguments alike — estimated by `TokenEstimate`, and each
/// message that has ended at the provider's own count, or at its estimate
/// when the provider reported none.
///
/// The session records the total at most every `interval` while a message
/// streams, and always once a message ends, so the event log gains a few
/// lines a second, never one per delta.
struct OutputTally {
    static let interval: TimeInterval = 0.25

    /// The messages of this run that have ended.
    private var ended = 0
    /// The message streaming now.
    private var streaming = 0.0
    private var recorded: Int?
    private var recordedAt = Date.distantPast

    var total: Int {
        ended + Int(streaming.rounded())
    }

    /// A message starts streaming. One a retry abandoned never ended, so
    /// what it had streamed is not counted.
    mutating func startMessage() {
        streaming = 0
    }

    mutating func add(_ delta: String) {
        streaming += TokenEstimate.tokens(in: delta)
    }

    /// `reported`: the provider's output tokens for the message, or 0.
    mutating func endMessage(reported: Int) {
        ended += reported > 0 ? reported : Int(streaming.rounded())
        streaming = 0
    }

    /// The total to record at `now`: once it has changed, and, unless the
    /// message has just ended, `interval` after the last one recorded.
    mutating func take(at now: Date, messageEnded: Bool = false) -> Int? {
        let total = total
        guard total > 0, total != recorded,
              messageEnded || now.timeIntervalSince(recordedAt) >= Self.interval
        else { return nil }
        recorded = total
        recordedAt = now
        return total
    }
}
