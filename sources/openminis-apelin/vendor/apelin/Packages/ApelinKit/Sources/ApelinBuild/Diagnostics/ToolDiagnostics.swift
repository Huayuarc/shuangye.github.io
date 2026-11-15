import ApelinProtocol
import Foundation

/// Structured diagnostics out of what clang, swiftc and the linker print:
/// `file:line:column: severity: message`, `ld: warning: …`, `clang: error: …`,
/// `Undefined symbols for architecture arm64:`. A file under the project
/// comes back relative to it; anything else keeps its own path.
public enum ToolDiagnostics {
    private static let located = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(?:(\d+):)? (fatal error|error|warning|note|remark): (.*)$"#,
    )
    private static let unlocated = try! NSRegularExpression(
        pattern: #"^(ld|clang|swiftc|swift-frontend|lipo|strip|dsymutil|error|warning)(?:\([^)]*\))?: (?:(fatal error|error|warning|note)\s*: )?(.*)$"#,
    )

    public static func parse(_ output: String, tool: String, projectRoot: String) -> [ProjectDiagnostic] {
        var out: [ProjectDiagnostic] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if let diagnostic = parseLine(line, tool: tool, projectRoot: projectRoot) {
                out.append(diagnostic)
            }
        }
        return out
    }

    public static func parseLine(_ line: String, tool: String, projectRoot: String) -> ProjectDiagnostic? {
        let range = NSRange(line.startIndex..., in: line)
        if let match = located.firstMatch(in: line, range: range) {
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: line).map { String(line[$0]) }
            }
            let file = relative(group(1) ?? "", to: projectRoot)
            return ProjectDiagnostic(
                code: "\(tool).\(severityName(group(4) ?? ""))",
                severity: severity(group(4) ?? ""),
                message: group(5) ?? line,
                file: file,
                line: group(2).flatMap { Int($0) },
                column: group(3).flatMap { Int($0) },
            )
        }
        if let match = unlocated.firstMatch(in: line, range: range) {
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: line).map { String(line[$0]) }
            }
            let source = group(1) ?? tool
            var kind = group(2)
            var message = group(3) ?? line
            if kind == nil {
                // `ld: warning: x` reads as source ld, message `warning: x`
                for candidate in ["error", "warning", "note"] where message.hasPrefix(candidate + ": ") {
                    kind = candidate
                    message = String(message.dropFirst(candidate.count + 2))
                }
            }
            if source == "error" || source == "warning" {
                kind = source
            }
            // `ld: library 'x' not found`: a tool that names no severity is
            // telling why it stopped
            let kindName = kind ?? "error"
            return ProjectDiagnostic(
                code: "\(tool).\(severityName(kindName))",
                severity: severity(kindName),
                message: message,
            )
        }
        if line.hasPrefix("Undefined symbols for architecture") {
            return ProjectDiagnostic(code: "\(tool).error", severity: .error, message: line)
        }
        return nil
    }

    private static func severity(_ text: String) -> DiagnosticSeverity {
        switch text {
        case "error", "fatal error": .error
        case "warning": .warning
        default: .note
        }
    }

    private static func severityName(_ text: String) -> String {
        severity(text).rawValue
    }

    private static func relative(_ path: String, to root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        if path.hasPrefix("./") {
            return String(path.dropFirst(2))
        }
        return path
    }
}
