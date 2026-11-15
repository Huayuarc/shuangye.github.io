@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

/// The agent's file tools never write a repository's git directory: a config
/// or hook written there would feed every git the host runs as mobile.
@Suite("Git directory writes")
struct GitDirectoryWriteTests {
    let home: TemporaryHome
    let tools: ProjectFileTools

    init() throws {
        home = try TemporaryHome()
        try home.write("Sources/Tweak.m", "int a = 1;\n")
        try home.write(".git/config", "[core]\n\tbare = false\n")
        try home.write(".git/HEAD", "ref: refs/heads/main\n")
        try FileManager.default.createDirectory(
            at: home.projectURL.appendingPathComponent(".git/hooks", isDirectory: true),
            withIntermediateDirectories: true,
        )
        tools = try ProjectFileTools(root: ScopedRoot(home.projectURL))
    }

    /// Refused as a git directory write, not for some other reason.
    private func refused(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch let error as PathPolicyError {
            if case .gitDirectory = error {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(home.projectURL.appendingPathComponent(relative).path, &info) == 0
    }

    @Test
    func `the project's .git config and hooks are refused`() throws {
        defer { home.remove() }
        #expect(refused { _ = try tools.writeFile(["path": ".git/config", "content": "[core]\n\tfsmonitor = x\n"]) })
        #expect(refused {
            _ = try tools.patchFile(["path": ".git/config", "old_text": "bare = false", "new_text": "pager = x"])
        })
        #expect(refused { _ = try tools.createFile(["path": ".git/hooks/pre-commit", "content": "#!/bin/sh\n"]) })
        #expect(refused { _ = try tools.writeFile(["path": ".git/modules/sub/config", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "Sources/../.git/config", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": ".GIT/config", "content": "x"]) })
        #expect(try home.read(".git/config") == "[core]\n\tbare = false\n")
        #expect(!exists(".git/hooks/pre-commit"))
        #expect(!exists(".git/modules"))
    }

    @Test
    func `a nested repository's .git is refused, and so is making one`() throws {
        defer { home.remove() }
        try home.write("sub/.git/config", "[core]\n")
        #expect(refused { _ = try tools.writeFile(["path": "sub/.git/config", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "fresh/.git/config", "content": "x"]) })
        #expect(refused { _ = try tools.createFile(["path": "other/.git", "content": "gitdir: ../store\n"]) })
        #expect(try home.read("sub/.git/config") == "[core]\n")
        #expect(!exists("fresh"))
        #expect(!exists("other/.git"))
    }

    @Test
    func `a .git file and the directory it names are refused`() throws {
        defer { home.remove() }
        try home.write("module/.git", "gitdir: ../store/module\n")
        try home.write("store/module/config", "[core]\n")
        #expect(refused { _ = try tools.writeFile(["path": "module/.git", "content": "gitdir: /tmp\n"]) })
        #expect(refused { _ = try tools.writeFile(["path": "store/module/config", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "store/module/hooks/post-checkout", "content": "x"]) })
        #expect(try home.read("store/module/config") == "[core]\n")
        #expect(try home.read("module/.git") == "gitdir: ../store/module\n")
        // A sibling of the named directory is an ordinary project folder.
        _ = try tools.writeFile(["path": "store/notes.txt", "content": "ok\n"])
    }

    @Test
    func `a .git that is a link protects the folder it names`() throws {
        defer { home.remove() }
        try home.write("elsewhere/config", "[core]\n")
        try FileManager.default.createDirectory(
            at: home.projectURL.appendingPathComponent("checkout", isDirectory: true),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createSymbolicLink(
            atPath: home.projectURL.appendingPathComponent("checkout/.git").path,
            withDestinationPath: "../elsewhere",
        )
        #expect(refused { _ = try tools.writeFile(["path": "elsewhere/config", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "elsewhere/hooks/pre-commit", "content": "x"]) })
        #expect(try home.read("elsewhere/config") == "[core]\n")
    }

    @Test
    func `a .git link whose target does not exist yet protects that path`() throws {
        defer { home.remove() }
        try FileManager.default.createDirectory(
            at: home.projectURL.appendingPathComponent("checkout", isDirectory: true),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createSymbolicLink(
            atPath: home.projectURL.appendingPathComponent("checkout/.git").path,
            withDestinationPath: "../store/repo.git",
        )
        #expect(refused { _ = try tools.writeFile(["path": "store/repo.git/config", "content": "x"]) })
        #expect(refused { _ = try tools.createFile(["path": "store/repo.git/HEAD", "content": "x"]) })
        #expect(!exists("store"))
        _ = try tools.writeFile(["path": "store/notes.txt", "content": "ok\n"])
    }

    @Test
    func `the commondir a .git directory names is refused`() throws {
        defer { home.remove() }
        try home.write(".git/commondir", "../shared\n")
        try home.write("shared/config", "[core]\n")
        #expect(refused { _ = try tools.writeFile(["path": "shared/config", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "shared/hooks/pre-commit", "content": "x"]) })
        #expect(try home.read("shared/config") == "[core]\n")
        _ = try tools.writeFile(["path": "sharedness/notes.txt", "content": "ok\n"])
    }

    @Test
    func `a link inside the project that points into .git is not written through`() throws {
        defer { home.remove() }
        try FileManager.default.createSymbolicLink(
            atPath: home.projectURL.appendingPathComponent("alias").path,
            withDestinationPath: home.projectURL.appendingPathComponent(".git").path,
        )
        try FileManager.default.createSymbolicLink(
            atPath: home.projectURL.appendingPathComponent("relative").path,
            withDestinationPath: ".git/hooks",
        )
        #expect(refused { _ = try tools.writeFile(["path": "alias/config", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "alias/hooks/pre-commit", "content": "x"]) })
        #expect(refused { _ = try tools.createFile(["path": "relative/post-merge", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "alias/info/new/exclude", "content": "x"]) })
        #expect(try home.read(".git/config") == "[core]\n\tbare = false\n")
        #expect(!exists(".git/hooks/pre-commit"))
        #expect(!exists(".git/hooks/post-merge"))
        #expect(!exists(".git/info"))
    }

    @Test
    func `a write whose temporary would be renamed into .git is refused before anything is made`() throws {
        defer { home.remove() }
        // The tools have no rename of their own: every write lands by
        // renaming a temporary beside the target, so a target in .git is a
        // rename into .git, and neither the temporary nor a folder is left.
        #expect(refused { _ = try tools.writeFile(["path": ".git/HEAD", "content": "ref: refs/heads/evil\n"]) })
        #expect(refused { _ = try tools.writeFile(["path": ".git/info/attributes", "content": "* diff=x\n"]) })
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: home.projectURL.appendingPathComponent(".git").path,
        )
        #expect(Set(entries) == ["config", "HEAD", "hooks"])
        #expect(try home.read(".git/HEAD") == "ref: refs/heads/main\n")
    }

    @Test
    func `reading a git directory, and writing beside one, is still allowed`() throws {
        defer { home.remove() }
        #expect(try tools.readFile(["path": ".git/config"]).contains("bare = false"))
        _ = try tools.writeFile(["path": "Sources/Tweak.m", "content": "int a = 2;\n"])
        _ = try tools.writeFile(["path": "gitnotes/.gitignore", "content": "build/\n"])
        _ = try tools.writeFile(["path": ".github/workflows/ci.yml", "content": "on: push\n"])
        #expect(try home.read("gitnotes/.gitignore") == "build/\n")
    }

    /// Writes `path` with the write tool, answering whether it was refused
    /// as a git directory write; any other failure is recorded.
    private func refusedWrite(_ path: String) -> Bool {
        do {
            _ = try tools.writeFile(["path": .string(path), "content": "ref: refs/heads/main\n"])
            return false
        } catch PathPolicyError.gitDirectory {
            return true
        } catch {
            Issue.record("\(path): \(error)")
            return false
        }
    }

    @Test(
        arguments: [
            // The files in the order they come, and the one refused: after a
            // HEAD nothing goes below objects/ or refs/, and no HEAD goes
            // beside both, or beside a commondir.
            (["HEAD", "objects/pack/x"], "objects/pack/x"),
            (["HEAD", "refs/heads/main"], "refs/heads/main"),
            (["objects/pack/x", "HEAD", "refs/heads/main"], "refs/heads/main"),
            (["refs/heads/main", "HEAD", "objects/pack/x"], "objects/pack/x"),
            (["objects/pack/x", "refs/heads/main", "HEAD"], "HEAD"),
            (["refs/heads/main", "objects/pack/x", "HEAD"], "HEAD"),
            (["config", "objects/x", "refs/x", "HEAD"], "HEAD"),
            (["config", "HEAD", "objects/x"], "objects/x"),
            (["HEAD", "commondir"], "commondir"),
            (["commondir", "HEAD"], "HEAD"),
            (["commondir", "config", "HEAD"], "HEAD"),
            (["objects/x", "refs/x", "head"], "head"),
        ],
    )
    func `a bare repository's layout is never completed, whatever order its files arrive in`(order: [String], refusedFile: String) {
        defer { home.remove() }
        // Every file before the refused one lands.
        for file in order.dropLast() {
            #expect(!refusedWrite("sub/\(file)"), "sub/\(file) after \(order)")
        }
        #expect(order.last == refusedFile)
        #expect(refusedWrite("sub/\(refusedFile)"), "sub/\(refusedFile) after \(order)")
        // And so at no point did git see a repository there.
        let sub = home.projectURL.appendingPathComponent("sub").path
        let hasHEAD = exists("sub/HEAD")
        let hasStores = exists("sub/objects") && exists("sub/refs")
        #expect(!(hasHEAD && (hasStores || exists("sub/commondir"))), "\(sub) became a git directory")
    }

    @Test
    func `a bare repository's layout at the project root is refused too`() {
        defer { home.remove() }
        #expect(!refusedWrite("objects/x"))
        #expect(!refusedWrite("refs/x"))
        #expect(refusedWrite("HEAD"))
    }

    @Test
    func `a directory that already has the layout is a git directory: nothing is written in it`() throws {
        defer { home.remove() }
        try home.write("store/repo.git/HEAD", "ref: refs/heads/main\n")
        try home.write("store/repo.git/objects/info/packs", "")
        try home.write("store/repo.git/refs/heads/.keep", "")
        try home.write("worktree/HEAD", "ref: refs/heads/main\n")
        try home.write("worktree/commondir", "../store/repo.git\n")
        for path in [
            "store/repo.git/config", "store/repo.git/HEAD", "store/repo.git/commondir",
            "store/repo.git/hooks/post-checkout", "store/repo.git/info/attributes",
            "store/repo.git/objects/ab/cdef", "store/repo.git/refs/heads/evil",
            "worktree/config", "worktree/HEAD", "worktree/hooks/pre-commit",
        ] {
            #expect(refusedWrite(path), "\(path)")
        }
        #expect(try home.read("store/repo.git/HEAD") == "ref: refs/heads/main\n")
        #expect(!exists("store/repo.git/config"))
        // Beside it, and in a folder with only part of the layout, is fine.
        #expect(!refusedWrite("store/notes.txt"))
    }

    @Test
    func `ordinary project files named config, HEAD or commondir are written`() {
        defer { home.remove() }
        for path in [
            "config", "Sources/config", "Resources/HEAD", "Docs/commondir", "Docs/HEAD.md",
            "Pkg/config", "Pkg/HEAD", "Pkg/HEAD.d/objects/a", "Assets/objects/a.png", "Assets/refs/b.txt",
            "Assets/config", "Assets/refs/HEAD", "Assets/objects/HEAD",
        ] {
            #expect(!refusedWrite(path), "\(path)")
        }
    }

    @Test
    func `resolving a write target refuses a git directory, so the approval gate's check does too`() throws {
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        #expect(refused { _ = try root.resolveForWrite(".git/config") })
        #expect(refused { _ = try root.resolveForWrite("sub/.git") })
    }
}

/// A write looks for `.git` files across the project once, however many
/// times the path is resolved and checked on its way to the disk.
@Suite("Git directory walks")
struct GitDirectoryWalkTests {
    /// Counts the walks a root's `onGitWalk` reports.
    final class WalkCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.withLock { count }
        }

        func record() {
            lock.withLock { count += 1 }
        }
    }

    @Test
    func `one write call through the runner walks the project once`() async throws {
        let walks = WalkCount()
        let harness = try DigestApprovalTests.Harness(onGitWalk: { walks.record() })
        defer { harness.home.remove() }
        try harness.home.write("Sources/Tweak.m", "int a = 1;\n")

        _ = try await harness.run(.fileWrite, ["path": "Sources/Tweak.m", "content": "int a = 2;\n"])
        #expect(walks.value == 1)
        _ = try await harness.run(
            .fileEdit,
            ["path": "Sources/Tweak.m", "old_text": "a = 2", "new_text": "a = 3"],
        )
        #expect(walks.value == 2)
        _ = try await harness.run(.fileCreate, ["path": "Sources/New.m", "content": "int b;\n"])
        #expect(walks.value == 3)
        #expect(try harness.home.read("Sources/Tweak.m") == "int a = 3;\n")
    }

    @Test
    func `commit looks at the target's own path again, though not at the walk`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let walks = WalkCount()
        var root = try ScopedRoot(home.projectURL)
        root.onGitWalk = { walks.record() }
        let target = try root.resolveForWrite("repo/inner/config")
        try home.write("repo/.git", "gitdir: inner\n")
        #expect(throws: PathPolicyError.gitDirectory("repo/inner/config")) {
            try target.commit(Data("x".utf8), exclusive: false)
        }
        #expect(walks.value == 1)
    }

    @Test
    func `a folder the walk cannot read refuses the write`() throws {
        let home = try TemporaryHome()
        let locked = home.projectURL.appendingPathComponent("locked").path
        defer {
            chmod(locked, 0o755)
            home.remove()
        }
        try home.write("locked/sub/.git", "gitdir: ../../store\n")
        chmod(locked, 0)
        let root = try ScopedRoot(home.projectURL)
        #expect(throws: PathPolicyError.self) { _ = try root.resolveForWrite("store/config") }
        #expect(!FileManager.default.fileExists(atPath: home.projectURL.appendingPathComponent("store").path))
    }
}
