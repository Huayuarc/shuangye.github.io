import Foundation
import KWWKAI

/// The summary a compaction leaves for the reader. kwwk puts its recap
/// first in the conversation, as a user message the model reads in
/// markup: the earlier history, the current turn's beginning when it was
/// cut, and a ledger of the files read and changed. The reader gets the
/// two summaries as plain text; the ledger stays the model's.
enum CompactionRecap {
    /// The sections that summarise, in the order the recap gives them.
    private static let sections = ["history", "current-turn-prefix"]

    /// The summary in `messages`' recap, or nil when they do not start
    /// with one. A recap in a shape this does not know is given whole.
    static func summary(of messages: [Message]) -> String? {
        guard case let .user(recap)? = messages.first, recap.source == .compaction else { return nil }
        let text = recap.content.compactMap { block -> String? in
            if case let .text(content) = block {
                return content.text
            }
            return nil
        }.joined(separator: "\n")
        let summaries = sections.compactMap { section(named: $0, in: text) }
        let summary = (summaries.isEmpty ? text : summaries.joined(separator: "\n\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    /// The text of `<name>…</name>`, unescaped; nil when absent or empty.
    /// Its text is escaped, so the first closing tag is its own.
    private static func section(named name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound ..< text.endIndex)
        else { return nil }
        let content = unescaped(String(text[open.upperBound ..< close.lowerBound]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    /// The five entities kwwk escapes, `&amp;` last so that an escaped
    /// entity reads as written.
    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
