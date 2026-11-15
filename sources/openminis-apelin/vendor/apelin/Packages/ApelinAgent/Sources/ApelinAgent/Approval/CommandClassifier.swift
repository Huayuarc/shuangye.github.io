import enum ApelinCore.CanonicalPath
import ApelinProtocol
import Foundation
import KWWKAI

/// Turns `shell_run`'s arguments into a `RunCodeInvocation`, structurally.
///
/// Shell text becomes a plain argv only when it is one simple command made
/// of words: bare words, single-quoted strings, and double-quoted strings
/// with no expansion inside. Anything a shell would interpret — `;`, `&`,
/// `|`, redirection, `$`, backticks, globs, braces, `~`, comments, a
/// leading `NAME=value`, a newline — leaves it as `.shell`, which no preset
/// matches. So `ls; rm -rf ~` is never "an `ls`".
public enum CommandClassifier {
    public static func classify(_ arguments: JSONValue) throws -> RunCodeInvocation {
        // Two forms that disagree would run whichever came first here, not
        // necessarily the one the model meant.
        if case let .object(fields) = arguments, ["argv", "command", "script"].count(where: { fields[$0] != nil }) > 1 {
            throw ToolArgumentError("Pass one of argv, command or script, not several.")
        }
        if let argv = arguments.argStrings("argv") {
            guard let first = argv.first, !first.isEmpty else { throw ToolArgumentError("argv is empty") }
            return .argv(argv)
        }
        if let script = arguments.argString("script") {
            let interpreter = arguments.argString("interpreter") ?? "sh"
            return .script(interpreter: interpreter, source: script)
        }
        if let command = arguments.argString("command") {
            if let words = plainWords(command), !words.isEmpty {
                return .argv(words)
            }
            return .shell(command)
        }
        throw ToolArgumentError("shell_run needs argv, command or script")
    }

    /// The words of `text` if it is one simple command, else nil.
    public static func plainWords(_ text: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var index = text.startIndex
        let metacharacters: Set<Character> = [
            ";", "&", "|", "<", ">", "(", ")", "$", "`", "*", "?", "[", "]", "{", "}", "~", "#", "!", "\\", "\n", "\r",
        ]

        while index < text.endIndex {
            let character = text[index]
            if character == " " || character == "\t" {
                if inWord {
                    words.append(current); current = ""; inWord = false
                }
            } else if character == "'" {
                guard let close = text[text.index(after: index)...].firstIndex(of: "'") else { return nil }
                current += text[text.index(after: index) ..< close]
                inWord = true
                index = close
            } else if character == "\"" {
                guard let close = text[text.index(after: index)...].firstIndex(of: "\"") else { return nil }
                let inner = text[text.index(after: index) ..< close]
                if inner.contains(where: { $0 == "$" || $0 == "`" || $0 == "\\" || $0 == "!" }) {
                    return nil
                }
                current += inner
                inWord = true
                index = close
            } else if metacharacters.contains(character) {
                return nil
            } else {
                current.append(character)
                inWord = true
            }
            index = text.index(after: index)
        }
        if inWord {
            words.append(current)
        }

        // `NAME=value cmd` changes the command's environment.
        if let first = words.first, let equals = first.firstIndex(of: "="),
           first[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), equals != first.startIndex
        {
            return nil
        }
        return words
    }
}

/// A user-editable entry in the command presets: which plain commands run
/// without asking under Confirm.
public struct CommandPreset: Sendable, Hashable, Codable {
    /// Shown in settings and recorded as approval evidence.
    public var name: String
    /// A bare executable name. A path never matches.
    public var executable: String
    /// Arguments that must follow the executable, in order.
    public var argumentPrefix: [String]
    /// Whether further arguments may follow the prefix.
    public var allowsFurtherArguments: Bool
    /// Every further argument that is a path (and every `--opt=value`
    /// value) must stay inside the project.
    public var pathArgumentsStayInProject: Bool

    public init(
        name: String,
        executable: String,
        argumentPrefix: [String] = [],
        allowsFurtherArguments: Bool = true,
        pathArgumentsStayInProject: Bool = true,
    ) {
        self.name = name
        self.executable = executable
        self.argumentPrefix = argumentPrefix
        self.allowsFurtherArguments = allowsFurtherArguments
        self.pathArgumentsStayInProject = pathArgumentsStayInProject
    }

    /// Whether `argv` is this preset, with `root` judging path arguments
    /// read from `workingDirectory` (relative to the root), as the session
    /// host reads them: every argument after `--`, and every one that is not
    /// an option, is a path; so is an option's `=value`.
    func matches(_ argv: [String], root: ScopedRoot, workingDirectory: String = ".") -> Bool {
        guard let executable = argv.first, executable == self.executable, !executable.contains("/") else {
            return false
        }
        let rest = Array(argv.dropFirst())
        guard rest.count >= argumentPrefix.count, Array(rest.prefix(argumentPrefix.count)) == argumentPrefix else {
            return false
        }
        let further = rest.dropFirst(argumentPrefix.count)
        if !allowsFurtherArguments && !further.isEmpty {
            return false
        }
        if further.contains(where: { $0.contains("\0") }) {
            return false
        }
        let directory = workingDirectory.isEmpty ? "." : workingDirectory
        guard root.mayReach(directory) else { return false }
        let reach = { (path: String) in
            root.mayReach(path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path))
        }
        // An option the session host refuses (writes a file, runs a program,
        // reads names from a list file, leaves the repository or reaches a
        // submodule) makes the call ask; the rule is the host's own.
        guard let paths = RunCodePresetRule.pathArguments(
            Array(further),
            executable: executable,
            subcommand: executable == "git" ? argumentPrefix.first : nil,
        ) else {
            return false
        }
        return !pathArgumentsStayInProject || paths.allSatisfy(reach)
    }
}

extension ScopedRoot {
    /// Whether `argument`, read as a path relative to the root, stays in
    /// it: the longest existing ancestor canonicalises inside the root and
    /// the rest has no `..`.
    func mayReach(_ argument: String) -> Bool {
        if argument.hasPrefix("~") {
            return false
        }
        let joined = argument.hasPrefix("/") ? argument : (path as NSString).appendingPathComponent(argument)
        let parts = Self.split(joined)
        for count in stride(from: parts.count, through: 0, by: -1) {
            let prefix = "/" + parts.prefix(count).joined(separator: "/")
            guard let real = CanonicalPath.resolve(prefix) else {
                // A name that exists but does not resolve is a dangling link.
                var info = stat()
                if lstat(prefix, &info) == 0 {
                    return false
                }
                continue
            }
            let remainder = parts.dropFirst(count)
            if remainder.contains("..") {
                return false
            }
            return contains(real)
        }
        return false
    }
}
