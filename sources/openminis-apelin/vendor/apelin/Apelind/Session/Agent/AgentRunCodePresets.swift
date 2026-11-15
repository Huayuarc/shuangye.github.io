import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// What Confirm lets through on the host's own reading, with no user
/// approval: the read-only commands ApelinAgent's default presets name (ls,
/// cat, head, tail, wc, file, stat, `plutil -p`, `git status|diff|log`),
/// and only when they stay read-only and in the project. Anything else is
/// not a preset and needs an approval the app gave. Which words make a
/// preset is `RunCodePresetRule` (ApelinProtocol), the rule the agent reads
/// too; the paths and the repository are checked here.
///
/// A file tool's every path argument (and every `--option=value` value)
/// must stay inside the project, read from the working directory: the
/// longest part of it that exists canonicalises inside, and the rest has no
/// `..`; no option reads a list of names from a file. git takes no option
/// that writes a file, runs a program, moves the repository or reaches a
/// submodule, and only in the repository git itself names, a plain one of
/// the project with no submodules, whose own config, as git reads it, names
/// nothing git would run (`repositoryConfigIsInert`); it then runs with
/// configured commands and signature programs overridden, submodules
/// ignored and no system or global config read.
extension AgentRunCode {
    /// A preset as the host runs it: its argv (the executable still a bare
    /// name) and what it adds to the environment.
    struct Preset: Equatable, Sendable {
        var argv: [String]
        var environment: [String]
    }

    /// The overrides every git preset runs with, before its subcommand.
    static let gitOverrides = [
        "--no-pager",
        "--no-optional-locks",
        "-c", "submodule.recurse=false",
        "-c", "core.fsmonitor=false",
        "-c", "core.pager=cat",
        "-c", "diff.external=",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.attributesFile=/dev/null",
        "-c", "safe.bareRepository=explicit",
        // A signed commit in history starts no signature program.
        "-c", "gpg.program=/nonexistent/gpg",
        "-c", "gpg.openpgp.program=/nonexistent/gpg",
        "-c", "gpg.x509.program=/nonexistent/gpgsm",
        "-c", "gpg.ssh.program=/nonexistent/ssh-keygen",
        "-c", "log.showSignature=false",
    ]

    /// What every git preset adds to the environment, and the repository
    /// check runs with too: no system or global config, no repository
    /// above the project.
    private static func gitEnvironment(project: String) -> [String] {
        [
            "GIT_CONFIG_NOSYSTEM=1",
            "GIT_CONFIG_GLOBAL=/dev/null",
            "GIT_ATTR_NOSYSTEM=1",
            "GIT_OPTIONAL_LOCKS=0",
            "GIT_PAGER=cat",
            "GIT_CEILING_DIRECTORIES=\((project as NSString).deletingLastPathComponent)",
        ]
    }

    /// The preset `spec` is, run from `directory` (canonical, inside
    /// `project`), or nil when it is not one. `installRoot` finds the git
    /// that reads a repository's config.
    static func preset(
        _ spec: RunCodeSpec,
        directory: String,
        project: String,
        installRoot: String,
    ) async -> Preset? {
        // The words first (the rule the agent reads too), then each path by
        // realpath and a repository's config by git, which only the host can.
        guard case let .argv(argv) = spec, let executable = argv.first,
              let paths = RunCodePresetRule.pathArguments(of: argv),
              paths.allSatisfy({ staysInside($0, directory: directory, project: project) })
        else { return nil }
        guard executable == "git" else { return Preset(argv: argv, environment: []) }
        guard await repositoryConfigIsInert(from: directory, project: project, installRoot: installRoot) else {
            return nil
        }
        let subcommand = argv[1]
        let rest = Array(argv.dropFirst(2))
        let noPrograms = subcommand == "status" ? [] : ["--no-ext-diff", "--no-textconv"]
        let noSubmodules = subcommand == "log" ? [] : ["--ignore-submodules=all"]
        return Preset(
            argv: ["git"] + gitOverrides + [subcommand] + noPrograms + noSubmodules + rest,
            environment: gitEnvironment(project: project),
        )
    }

    /// Whether `argument`, read from `directory`, stays in `project`: the
    /// longest part of it that exists canonicalises inside, the rest has no
    /// `..`, and no part of it is a link that leads nowhere.
    private static func staysInside(_ argument: String, directory: String, project: String) -> Bool {
        guard !argument.isEmpty, !CanonicalPath.containsNUL(argument) else { return false }
        let joined = argument.hasPrefix("/") ? argument : directory + "/" + argument
        let parts = CanonicalPath.components(joined).map(String.init)
        for count in stride(from: parts.count, through: 0, by: -1) {
            let prefix = "/" + parts.prefix(count).joined(separator: "/")
            guard let real = CanonicalPath.resolve(prefix) else {
                var metadata = stat()
                if lstat(prefix, &metadata) == 0 {
                    return false
                }
                continue
            }
            return !parts.dropFirst(count).contains("..") && CanonicalPath.isCanonical(real, inside: project)
        }
        return false
    }

    /// The keys a repository's own config may hold for a git preset to run
    /// without asking, as `git config --list` names them (section and key
    /// lowercased): what `git init` and a clone write, the author, and the
    /// task a clone was made by (`apelin.cloneTask`, ApelinEnvironment's
    /// GitService). Anything else — a filter, a textconv or external diff
    /// driver, an fsmonitor, a pager, an include — is something git might
    /// run.
    private static let inertConfigKeys: [String: Set<String>] = [
        "core": [
            "repositoryformatversion", "filemode", "bare", "logallrefupdates", "ignorecase",
            "precomposeunicode", "symlinks",
        ],
        "user": ["name", "email"],
        "apelin": ["clonetask"],
    ]

    /// The keys that are inert only under a subsection: `[remote "origin"]`.
    private static let inertSubsectionKeys: [String: Set<String>] = [
        "remote": ["url", "fetch", "pushurl"],
        "branch": ["remote", "merge"],
    ]

    /// Asks git which repository it would use from `directory` — with the
    /// preset's own environment and overrides, as mobile — rather than
    /// modelling its discovery, which skips a `.git` that is not a
    /// repository and takes a folder with HEAD beside `objects`, `refs` or
    /// `commondir` as one. The answer must be a plain repository of the
    /// project: its git directory its own common one (no worktree, no
    /// `commondir`) and a real `<top level>/.git` directory inside the
    /// project, so a bare layout, which has no top level, never is; no
    /// submodule (`.gitmodules` at the top level, or `.git/modules`, each
    /// with a config of its own); and a config that is not a link, readable
    /// and inert. None of this leans on `safe.bareRepository`, which a git
    /// older than 2.38 ignores. Any error is not inert.
    private static func repositoryConfigIsInert(
        from directory: String,
        project: String,
        installRoot: String,
    ) async -> Bool {
        guard let git = findExecutable("git", in: DevelopmentEnvironment.searchPath(installRoot: installRoot)),
              let found = await capture(
                  [git] + gitOverrides + ["rev-parse", "--absolute-git-dir", "--git-common-dir", "--show-toplevel"],
                  environment: gitEnvironment(project: project) + ["HOME=/var/empty"],
                  directory: directory,
                  timeoutSeconds: 10,
              ),
              found.exitCode == 0, !found.truncated
        else { return false }
        let lines = found.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 4, lines[3].isEmpty, lines.prefix(3).allSatisfy({ !$0.isEmpty }) else { return false }
        // The common directory may come back relative to `directory`.
        let common = lines[1].hasPrefix("/") ? lines[1] : directory + "/" + lines[1]
        guard let gitDirectory = CanonicalPath.resolve(lines[0]),
              CanonicalPath.resolve(common) == gitDirectory,
              let topLevel = CanonicalPath.resolve(lines[2]),
              gitDirectory == topLevel + "/.git",
              CanonicalPath.isCanonical(gitDirectory, inside: project)
        else { return false }
        var metadata = stat()
        guard lstat(gitDirectory, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              lstat(gitDirectory + "/commondir", &metadata) != 0,
              lstat(gitDirectory + "/modules", &metadata) != 0,
              lstat(topLevel + "/.gitmodules", &metadata) != 0
        else { return false }
        return await configIsInert(at: gitDirectory + "/config", installRoot: installRoot)
    }

    /// Reads the config with git's own parser, which runs nothing — git
    /// takes several headers and a key on one line, and no hand-written
    /// reading keeps up with it — and holds every key it names to the
    /// allowlist. Any error, and any include, is not inert.
    private static func configIsInert(at path: String, installRoot: String) async -> Bool {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            return errno == ENOENT
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 64 * 1024,
              let names = await configNames(at: path, installRoot: installRoot)
        else { return false }
        return names.allSatisfy(isInertConfigName)
    }

    /// `git config --file <path> --list --name-only --null`, with no system
    /// or global config, as mobile (`capture`): every key's name, or nil
    /// when git cannot read the file.
    private static func configNames(at path: String, installRoot: String) async -> [String]? {
        guard let git = findExecutable("git", in: DevelopmentEnvironment.searchPath(installRoot: installRoot)),
              let listed = await capture(
                  [git, "config", "--file", path, "--list", "--name-only", "--null"],
                  environment: ["GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "HOME=/var/empty"],
                  timeoutSeconds: 10,
              ),
              listed.exitCode == 0, !listed.truncated
        else { return nil }
        return listed.stdout.split(separator: "\0").map(String.init)
    }

    /// `section.key` or `section.subsection.key` (the subsection may hold
    /// dots), against the allowlists; an `include.*` or `includeIf.*` key is
    /// in neither.
    private static func isInertConfigName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let section = parts.first.map(String.init), let key = parts.last.map(String.init) else {
            return false
        }
        if parts.count == 2 {
            return inertConfigKeys[section]?.contains(key) == true
        }
        return inertSubsectionKeys[section]?.contains(key) == true
    }
}
