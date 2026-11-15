import ApelinProtocol
import CoreGraphics
import Foundation

/// How far the conversation page follows a turn's output. A reply that
/// streams no faster than a reader keeps up with is followed to its end; a
/// faster one only until the turn's own message reaches the top of the
/// visible area, at most a page, so it never scrolls past the reader.
enum TurnFollowing {
    /// Faster than this a reader cannot keep up.
    static let fastTokensPerSecond = 50.0
    /// How long a turn's reply is watched before its pace counts, so that
    /// one burst is not taken for the pace.
    static let paceWindow: TimeInterval = 1

    /// The message a turn starts with: the newest user message a run has
    /// taken, or one just sent to an idle conversation. A message waiting
    /// for a running turn starts none yet.
    static func turnMessage(in rows: [ChatMessage]) -> UUID? {
        rows.last { $0.role == .user && !$0.isQueued }?.id
    }

    /// Roughly how many tokens the turn starting with `message` has replied
    /// so far, in its assistant rows (`TokenEstimate`). Thinking and calls
    /// are summarised in a line, so they leave the reader nothing to keep up
    /// with.
    static func replyTokens(in rows: [ChatMessage], after message: UUID) -> Double {
        guard let start = rows.lastIndex(where: { $0.id == message }) else { return 0 }
        return rows[rows.index(after: start)...]
            .filter { $0.role == .assistant }
            .reduce(0) { $0 + TokenEstimate.tokens(in: $1.text) }
    }

    /// Where following takes the list from `offset`: to `latest`, the offset
    /// that shows the newest content, while the reply is not too fast to
    /// read. A fast one goes no further than puts `messageTop` (the turn's
    /// message, in content coordinates) at `topInset` below the list's top
    /// edge, and never back up; once the message is there, the turn is
    /// followed no further.
    static func move(
        pace: Pace,
        offset: CGFloat,
        latest: CGFloat,
        messageTop: CGFloat,
        topInset: CGFloat,
    ) -> Move {
        guard pace.isFast else { return .latest }
        let limit = messageTop - topInset
        return latest < limit ? .latest : .stop(max(offset, limit))
    }

    enum Move: Equatable {
        /// To the newest content; the turn is still followed.
        case latest
        /// To this offset, and the turn is followed no more.
        case stop(CGFloat)
    }

    /// How fast a turn's reply streams: its estimated tokens a second,
    /// averaged over everything since its first text. That first update came
    /// at once (the first coalesced chunk, or a backlog the page caught up
    /// on), so it marks the start and is not counted itself.
    struct Pace {
        private var first: Sample?
        private var last: Sample?

        private struct Sample {
            let time: TimeInterval
            let tokens: Double
        }

        /// The reply holds `tokens` at `time`, in seconds of any monotonic
        /// clock.
        mutating func observe(tokens: Double, at time: TimeInterval) {
            guard tokens > 0 else { return }
            let sample = Sample(time: time, tokens: tokens)
            if first == nil {
                first = sample
            }
            last = sample
        }

        /// Nil until `paceWindow` has passed since the first text.
        var tokensPerSecond: Double? {
            guard let first, let last, last.time - first.time >= TurnFollowing.paceWindow else { return nil }
            return (last.tokens - first.tokens) / (last.time - first.time)
        }

        var isFast: Bool {
            (tokensPerSecond ?? 0) > TurnFollowing.fastTokensPerSecond
        }
    }
}
