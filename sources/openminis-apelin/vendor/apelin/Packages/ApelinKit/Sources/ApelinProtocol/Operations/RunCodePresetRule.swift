import ApelinCore
import Foundation

/// The words-only half of the rule that decides which `shell_run` calls
/// Confirm runs as presets, shared by both sides: the agent (ApelinAgent's
/// `CommandPreset`) reads it to decide whether to send a call as a preset,
/// and the session host (Apelind's `AgentRunCode.preset`) to decide whether
/// to run one. What only the host can do stays there: resolving each path
/// argument with realpath against the project, and reading a repository's
/// config with git.
///
/// The presets: the read-only file tools, `plutil -p` and
/// `git status|diff|log`. No option that writes a file, runs a program
/// (gpg and file's decompressors included), reads a file it names or a
/// list of names from one, follows a link or walks a tree, moves the
/// repository or reaches a submodule; `file` takes only an allowlist.
/// Every argument after `--`, every one that is not an option, and every
/// option's `=value` is a path, which must stay in the project.
public enum RunCodePresetRule {
    public static let fileTools: Set<String> = ["ls", "cat", "head", "tail", "wc", "file", "stat"]
    public static let gitSubcommands: Set<String> = ["status", "diff", "log"]

    /// The path arguments of `argv` when its words make it a preset, or nil
    /// when they do not.
    public static func pathArguments(of argv: [String]) -> [String]? {
        guard let executable = argv.first, argv.allSatisfy({ !CanonicalPath.containsNUL($0) }) else { return nil }
        let arguments = Array(argv.dropFirst())
        if fileTools.contains(executable) {
            return pathArguments(arguments, executable: executable)
        }
        let rest = Array(arguments.dropFirst())
        if executable == "plutil" {
            // -p and the files to print: any other option is another mode.
            return arguments.first == "-p" ? pathArguments(rest, executable: executable) : nil
        }
        guard executable == "git", let subcommand = arguments.first, gitSubcommands.contains(subcommand) else {
            return nil
        }
        return pathArguments(rest, executable: executable, subcommand: subcommand)
    }

    /// The path arguments among `arguments` — what follows the executable
    /// and the words that fix its mode (`-p`, the git subcommand, which
    /// `subcommand` names) — or nil when one is an option `executable`
    /// refuses.
    public static func pathArguments(
        _ arguments: [String],
        executable: String,
        subcommand: String? = nil,
    ) -> [String]? {
        var paths: [String] = []
        var options = true
        for argument in arguments {
            if options, argument == "--" {
                options = false
                continue
            }
            if options, argument.hasPrefix("-"), argument != "-" {
                if refuses(executable, argument, subcommand: subcommand) {
                    return nil
                }
                if let equals = argument.firstIndex(of: "=") {
                    let value = String(argument[argument.index(after: equals)...])
                    if !value.isEmpty {
                        paths.append(value)
                    }
                }
                continue
            }
            if argument != "-" {
                paths.append(argument)
            }
        }
        return paths
    }

    /// Whether `executable` refuses `argument` as a preset: for git, an
    /// option that writes a file (`--output`, `-o`), runs a program
    /// (`--ext-diff`, `--textconv`, `--exec-path`, `-c`), verifies a
    /// signature, which starts gpg (`--show-signature`, a format with `%G`
    /// in any of its spellings, `formatVerifiesSignature`), reads a file it
    /// names (`--no-index`, `-O`), moves the repository (`--git-dir`,
    /// `--work-tree`, `-C`) or reaches a submodule (`--submodule`,
    /// `--ignore-submodules`, `--recurse-submodules`), and a short one with
    /// anything attached but a count, a pickaxe (`gitAttachmentIsHarmless`)
    /// or more of `subcommand`'s value-less flags (`gitBundleIsValueless`);
    /// after `log`, `-c` and `-m` are its combined and merge diffs, and
    /// after `diff` or `log`, `-C` finds copies; for plutil (after `-p`), any option; for
    /// `file`, anything but an option that changes how it prints
    /// (`fileShortOptions`, `fileLongOptions`), so no magic file and no
    /// decompressor; for `ls`, one that follows a link or walks a tree; for
    /// any file tool, one that reads the names to work on from a file
    /// (`wc --files0-from`), which may name anything.
    public static func refuses(_ executable: String, _ argument: String, subcommand: String? = nil) -> Bool {
        let short = !argument.hasPrefix("--") && argument.hasPrefix("-")
        switch executable {
        case "git":
            let long = [
                "--ext-diff", "--textconv", "--no-index", "--output", "--exec-path", "--git-dir", "--work-tree",
                "--submodule", "--ignore-submodules", "--recurse-submodules", "--show-signature",
            ]
            if names(argument, oneOf: long) || formatVerifiesSignature(argument) {
                return true
            }
            guard short else { return false }
            if argument.count == 2 {
                guard let letter = argument.last, ["c", "o", "C", "O"].contains(letter) else { return false }
                return !gitValuelessFlags(subcommand).contains(letter)
            }
            return !gitAttachmentIsHarmless(argument) && !gitBundleIsValueless(argument, subcommand: subcommand)
        case "plutil":
            return argument.hasPrefix("-")
        case "file":
            if short {
                return !argument.dropFirst().allSatisfy(fileShortOptions.contains)
            }
            return !fileLongOptions.contains(argument)
        default:
            if names(argument, oneOf: ["--files0-from", "--files-from"]) {
                return true
            }
            guard executable == "ls" else { return false }
            return names(argument, oneOf: ["--dereference", "--recursive"])
                || (short && (argument.contains("L") || argument.contains("R")))
        }
    }

    /// What `file` may take: how it prints (brief, MIME, no padding, a NUL
    /// after the name, keep going) and whether it follows a link, which the
    /// path check has resolved already. Long ones spelled out in full; a
    /// short bundle is read letter by letter.
    public static let fileShortOptions: Set<Character> = ["b", "i", "L", "h", "k", "N", "0"]
    public static let fileLongOptions: Set<String> = [
        "--brief", "--mime", "--mime-type", "--mime-encoding", "--dereference", "--no-dereference",
        "--keep-going", "--no-pad", "--print0",
    ]

    /// Whether a short git option with something attached is one whose
    /// value is only a count or a pickaxe: `-<n>`; `-U`, `-l`, `-n` with
    /// digits; `-M`, `-C`, `-B` with a similarity (`-M50%`, `-B50/60`; after
    /// the subcommand, where `-C` finds copies); `-G` and `-S` with
    /// anything. Every other attachment — `-O<file>`, `-L<range>:<file>`,
    /// `-c<config>`, a bundle of flags — is refused.
    public static func gitAttachmentIsHarmless(_ argument: String) -> Bool {
        let digits = Set("0123456789")
        let body = argument.dropFirst()
        if body.allSatisfy(digits.contains) {
            return true
        }
        guard let letter = body.first else { return false }
        let value = body.dropFirst()
        switch letter {
        case "U", "l", "n": return value.allSatisfy(digits.contains)
        case "M", "C": return value.allSatisfy(digits.union(".%").contains)
        case "B": return value.allSatisfy(digits.union(".%/").contains)
        case "G", "S": return true
        default: return false
        }
    }

    /// Whether `argument` holds a placeholder git's pretty format reads as a
    /// signature's (`%G?`, `%GS`, `%GK`…), which starts gpg: a `%`, then the
    /// `+`, `-` or space git takes as a modifier, then `G`. A `%x` escape is
    /// printed as it is and never parsed again, so `%x25G` is no placeholder;
    /// `%%G` is refused with the rest, since that costs nothing.
    public static func formatVerifiesSignature(_ argument: String) -> Bool {
        var rest = argument[...]
        while let percent = rest.firstIndex(of: "%") {
            rest = rest[rest.index(after: percent)...]
            if rest.drop(while: { "+- ".contains($0) }).first == "G" {
                return true
            }
        }
        return false
    }

    /// The short git flags of `subcommand` that take no value, so a bundle
    /// of them is read letter by letter: for `status`, short format,
    /// branch, NUL, verbose and `-u` (`gitBundleIsValueless` reads its
    /// mode); for `diff`, patch, no patch, NUL, whitespace, reverse, text,
    /// and renames and copies with no similarity; for `log`, those and its
    /// combined (`-c`) and merge (`-m`) diffs. None for anything else.
    public static func gitValuelessFlags(_ subcommand: String?) -> Set<Character> {
        let diff: Set<Character> = ["p", "s", "z", "w", "b", "R", "a", "M", "C"]
        switch subcommand {
        case "status": return ["s", "b", "z", "v", "u"]
        case "diff": return diff
        case "log": return diff.union(["c", "m"])
        default: return []
        }
    }

    /// Whether a short git option is a bundle of `subcommand`'s value-less
    /// flags (`-sb`, `-pw`): `M` and `C` only last, so nothing is taken as
    /// their similarity, and status's `-u` only last, with nothing, `no`,
    /// `normal` or `all` attached as its mode (`-uno`).
    public static func gitBundleIsValueless(_ argument: String, subcommand: String?) -> Bool {
        let flags = gitValuelessFlags(subcommand)
        var body = argument.dropFirst()
        while let letter = body.popFirst() {
            guard flags.contains(letter) else { return false }
            if letter == "u" {
                return ["", "no", "normal", "all"].contains(String(body))
            }
            if letter == "M" || letter == "C" {
                return body.isEmpty
            }
        }
        return true
    }

    /// Whether `argument` is one of `options`, spelled out or abbreviated as
    /// getopt_long and git accept (`--files0` for `--files0-from`), with or
    /// without `=value`, or one of them with more after it.
    public static func names(_ argument: String, oneOf options: [String]) -> Bool {
        guard argument.hasPrefix("--") else { return false }
        let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        return options.contains { name.hasPrefix($0) || (name.count > 2 && $0.hasPrefix(name)) }
    }
}
