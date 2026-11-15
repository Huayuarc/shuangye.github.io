@testable import ApelinAgent
import Foundation
import Testing

@Suite("the project context's repository")
struct ProjectContextGitTests {
    private func folder(config: String?) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        if let config {
            try Data(config.utf8).write(to: root.appendingPathComponent(".git/config"))
        }
        return root.path
    }

    @Test
    func `a new project's repository reads as on main with nothing committed`() throws {
        let root = try folder(config: nil)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let status = GitStatusToolResponse(branch: "main", head: nil, entries: [
            GitStatusToolEntry(path: "apelin-project.json", index: "", worktree: "?"),
        ])
        #expect(ProjectContext.gitState(status, root: root)
            == "on branch main, no commits yet; 1 changed:  ? apelin-project.json.")
    }

    @Test
    func `changes are listed as git status --short spells them, the rest counted`() throws {
        let root = try folder(config: """
        [core]
        \tbare = false
        [remote "origin"]
        \turl = https://someone:secret@github.com/someone/tweak.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let entries = (0 ..< 14).map { GitStatusToolEntry(path: "Sources/\($0).m", index: "M", worktree: "") }
        let line = ProjectContext.gitState(
            GitStatusToolResponse(branch: "main", head: "0123456789abcdef", entries: entries),
            root: root,
        )
        #expect(line.hasPrefix("on branch main at 0123456; 14 changed: M  Sources/0.m, M  Sources/1.m"))
        #expect(line.contains("and 2 more"))
        #expect(line.hasSuffix("; origin https://github.com/someone/tweak.git."), "no credentials")
        #expect(!line.contains("secret"))
    }

    @Test
    func `a clean detached repository says so`() throws {
        let root = try folder(config: "[core]\n")
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(ProjectContext.gitState(GitStatusToolResponse(branch: nil, head: "fedcba9876"), root: root)
            == "detached at fedcba9; nothing to commit.")
    }

    @Test
    func `without the host's answer the line is read from .git, and no repository names git_init`() throws {
        let root = try folder(config: nil)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("ref: refs/heads/main\n".utf8).write(to: URL(fileURLWithPath: root + "/.git/HEAD"))
        #expect(ProjectContext.gitState(root) == "on branch main, no commits yet.")
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        #expect(ProjectContext.gitState(bare.path).contains("git_init"))
    }
}
