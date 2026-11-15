import ApelinCore
import ApelinProtocol
import Foundation

/// What the line under a running summary shows: its newest call, by the
/// reason the agent gave for it (the call's title when it gave none), and
/// for a file tool the file's name and, once its result is in, the lines it
/// added and removed.
struct ToolCallBanner: Hashable {
    var reason: String
    var file: String?
    var change: LineChange?

    struct LineChange: Hashable {
        let added: Int
        let removed: Int
    }

    /// The tools that write a file; the first line of their result ends
    /// with the lines added and removed, as `+a -b`. A call recorded under
    /// an earlier name counts too (`AgentToolName.canonical`).
    static let fileTools: Set<AgentToolName> = [.fileWrite, .fileCreate, .fileEdit]
}

extension ToolCallBanner {
    /// `title`: the call's own, for a call made without a reason (an older
    /// session, or a model that left it out).
    init(tool: String, arguments: String?, title: String) {
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        let reason = values?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = values?["path"]?.stringValue ?? ""
        self.init(
            reason: reason.isEmpty ? title : reason,
            file: Self.writesFile(tool) && !path.isEmpty ? (path as NSString).lastPathComponent : nil,
        )
    }

    private static func writesFile(_ tool: String) -> Bool {
        AgentToolName.canonical(tool).map(fileTools.contains) ?? false
    }

    /// The `+a -b` a file tool ends its result's first line with:
    /// "Patched Tweak.x (1 replacement, +3 -1)".
    static func lineChange(in output: String) -> LineChange? {
        let firstLine = output.prefix { $0 != "\n" }
        guard firstLine.hasSuffix(")"), let open = firstLine.lastIndex(of: "(") else { return nil }
        let figures = firstLine[firstLine.index(after: open) ..< firstLine.index(before: firstLine.endIndex)]
            .components(separatedBy: ", ").last?.split(separator: " ") ?? []
        guard figures.count == 2, figures[0].hasPrefix("+"), figures[1].hasPrefix("-"),
              let added = Int(figures[0].dropFirst()), let removed = Int(figures[1].dropFirst()) else { return nil }
        return LineChange(added: added, removed: removed)
    }
}
