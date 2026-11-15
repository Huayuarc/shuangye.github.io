import Foundation

/// A banner an agent asks for during a turn (`apelin_notification_send`, 2026-10-24),
/// for something the reader would want to know while away from Apelin.
///
/// No operation carries it. The tool records a `notice` event {title?, body}
/// in the session's `agent` task, and the session host posts it as the app
/// the way it posts a turn's end or an approval (Apelind/Session/Notice/),
/// deciding again on its own: plain text cut to these lengths, at most
/// `maximumPerTurn` between two of the session's prompts or turn ends,
/// nothing for a headless session, nothing for an event a reopened
/// session replays. The agent checks the same first, and keeps them
/// `minimumInterval` apart, so the model hears why one was not sent.
public enum AgentNoticeRules {
    public static let eventKind = "notice"
    /// The banner's subtitle, one line; the conversation's title heads it.
    public static let maximumTitleLength = 40
    /// About two lines of a banner, as a turn's own excerpt.
    public static let maximumBodyLength = 180
    public static let maximumPerTurn = 3
    /// The agent's pacing between two of a session's notices.
    public static let minimumInterval: TimeInterval = 30

    /// The text as one plain line: every run of white space, line breaks
    /// included, one space; control characters and bidirectional
    /// overrides, which could make a banner say something else than it
    /// reads, taken out. Nil when nothing is left.
    public static func plain(_ text: String?) -> String? {
        guard let text else { return nil }
        var line = String.UnicodeScalarView()
        var space = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                space = !line.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .control || bidirectionalControls.contains(scalar.value) {
                continue
            }
            if space {
                line.append(" ")
                space = false
            }
            line.append(scalar)
        }
        return line.isEmpty ? nil : String(line)
    }

    /// `plain`, cut to `limit` characters at a word where that keeps most of
    /// the line, with an ellipsis.
    public static func bounded(_ text: String?, limit: Int) -> String? {
        guard let line = plain(text) else { return nil }
        guard line.count > limit else { return line }
        var cut = String(line.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) < 30 {
            cut = String(cut[..<space])
        }
        let trailing = CharacterSet.whitespaces.union(.punctuationCharacters)
        while let last = cut.unicodeScalars.last, trailing.contains(last) {
            cut.unicodeScalars.removeLast()
        }
        return cut + "…"
    }

    private static let bidirectionalControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
    ]
}
