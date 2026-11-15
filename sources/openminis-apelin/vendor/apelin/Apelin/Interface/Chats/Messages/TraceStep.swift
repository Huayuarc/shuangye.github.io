import ApelinProtocol
import Foundation

/// A step of a summary's trace as the trace sheet lists it: its kind over
/// one line of its detail, and whether it has a page to open. A thought is
/// "Thoughts" over the start of its text; a call is its title, as the
/// transcript names it, over the reason the agent gave it (else the command
/// it runs or what it names, else its result); an approval is the call it
/// asked about over the decision.
struct TraceStep: Hashable {
    let id: UUID
    let title: String
    /// Empty while the step has nothing to say under its title.
    let subtitle: String
    /// Whether its page (`TraceStepController`) has anything to show.
    let hasDetail: Bool

    /// Past this many characters an excerpt ends in an ellipsis: more than
    /// a line holds at any width a sheet has, where a thought or a written
    /// file runs to thousands.
    static let excerptLength = 160

    init(_ message: ChatMessage) {
        id = message.id
        switch message.role {
        case .thinking:
            title = String(localized: "Thoughts")
            subtitle = Self.excerpt(message.text)
            hasDetail = !subtitle.isEmpty
        case let .approval(decision):
            title = message.approvalTitle
            subtitle = Self.decisionText(decision, runsAsRoot: message.runsAsRoot)
            hasDetail = !message.approvalDetail.isEmpty
        default:
            let detail = ToolCallDetail(detail: message.detail, title: message.text)
            title = message.text
            subtitle = Self.excerpt(Self.callLine(detail))
            hasDetail = !detail.sections.isEmpty
        }
    }

    /// The steps a summary's trace holds, in order and each id once, as a
    /// list takes them: the summary itself while its trace is empty, a
    /// summary standing in for what the turn will show.
    static func messages(of summary: ChatMessage) -> [ChatMessage] {
        guard !summary.trace.isEmpty else { return [summary] }
        var seen: Set<UUID> = []
        return summary.trace.filter { seen.insert($0.id).inserted }
    }

    /// The start of `text` on one line: each run of white space, line
    /// breaks included, as one space; past `excerptLength` characters, an
    /// ellipsis.
    static func excerpt(_ text: String) -> String {
        var line = ""
        var length = 0
        var spaced = false
        for character in text {
            guard !character.isWhitespace else {
                spaced = length > 0
                continue
            }
            let added = spaced ? 2 : 1
            guard length + added <= excerptLength else { return line + "…" }
            if spaced {
                line.append(" ")
            }
            line.append(character)
            length += added
            spaced = false
        }
        return line
    }

    /// An approval's decision, or that it waits for one.
    static func decisionText(_ decision: ApprovalDecision?, runsAsRoot: Bool) -> String {
        switch decision {
        case nil: runsAsRoot ? String(localized: "Root Approval Required") : String(localized: "Approval Required")
        case .approve: String(localized: "Allowed Once")
        case .deny: String(localized: "Denied")
        }
    }

    /// What a call's row says under its title: the reason the agent gave
    /// it, else its command line, else the file or pattern it names, else
    /// its result, else whatever it was given first.
    private static func callLine(_ detail: ToolCallDetail) -> String {
        var values: [String: String] = [:]
        for section in detail.sections {
            if let name = section.name, values[name] == nil {
                values[name] = section.value
            }
        }
        if let argv = values["argv"], let words = try? JSONDecoder().decode([String].self, from: Data(argv.utf8)) {
            values["argv"] = CommandLineText.quoted(words)
        }
        let named = ["reason", "argv", "command", "script", "path", "pattern", String(localized: "Result")]
            .lazy.compactMap { values[$0] }
            .first { !$0.allSatisfy(\.isWhitespace) }
        return named ?? detail.sections.first?.value ?? ""
    }
}
