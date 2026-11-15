import ApelinProtocol
import Darwin
import Foundation

/// What Apelin itself writes into a project folder that is none of the
/// project's: the agent's saved attachments, and the temporary files the
/// project metadata writer and the agent's file tools write beside a file
/// they replace. Every repository Apelin makes keeps them out through
/// `.git/info/exclude`, the repository's own list, which is never committed
/// or pushed; `.gitignore` is the project's.
public enum ProjectExcludes {
    public static let apelinFiles = [
        "/Attachments/",
        "/.apelin-metadata-*",
        ".*.apelin-*",
    ]
}

/// A new project's repository: what `git init -b main` leaves, written by
/// hand because apelin-build, which makes projects, does not link libgit2.
/// HEAD names `main`, which has no commit yet, and the config is git init's
/// own, with nothing in it that runs; `info/exclude` holds
/// `ProjectExcludes.apelinFiles`. It is written into the staging folder,
/// so the project and its repository arrive in `Projects/` together; the
/// first commit is the agent's or the user's. A workspace importing a
/// repository later replaces it while it is still untouched.
enum EmptyRepository {
    static let branch = "main"
    static let config = """
    [core]
    \trepositoryformatversion = 0
    \tfilemode = true
    \tbare = false
    \tlogallrefupdates = true

    """

    static func make(in root: URL) throws {
        let git = root.appendingPathComponent(".git", isDirectory: true)
        for folder in ["", "objects", "objects/info", "objects/pack", "refs", "refs/heads", "refs/tags", "info"] {
            let path = folder.isEmpty ? git.path : git.appendingPathComponent(folder).path
            guard mkdir(path, 0o755) == 0 else {
                throw ApelinError(.internal, "could not make the project's repository: \(String(cString: strerror(errno)))")
            }
        }
        try Data("ref: refs/heads/\(branch)\n".utf8).write(to: git.appendingPathComponent("HEAD"), options: .withoutOverwriting)
        try Data(config.utf8).write(to: git.appendingPathComponent("config"), options: .withoutOverwriting)
        let excludes = ProjectExcludes.apelinFiles.joined(separator: "\n") + "\n"
        try Data(excludes.utf8).write(to: git.appendingPathComponent("info/exclude"), options: .withoutOverwriting)
    }
}
