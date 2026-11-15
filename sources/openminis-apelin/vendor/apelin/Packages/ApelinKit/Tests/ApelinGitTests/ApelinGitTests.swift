import ApelinCore
@testable import ApelinGit
import Foundation
import XCTest

final class GitRepositoryTests: XCTestCase {
    private let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")

    private func temporaryRepository() throws -> (URL, GitRepository) {
        let base = URL(fileURLWithPath: CanonicalPath.resolve(NSTemporaryDirectory())!, isDirectory: true)
        let url = base.appendingPathComponent("apelin-git-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try (url, GitRepository.create(at: url))
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testStatusStageCommitDiffUnstage() throws {
        let (root, repository) = try temporaryRepository()
        XCTAssertEqual(repository.head(), GitHead(branch: "main", commit: nil))
        XCTAssertEqual(try repository.status(), [])

        try write("int main(void) { return 0; }\n", "Sources/main.c", in: root)
        try write("hello\n", "README", in: root)
        XCTAssertEqual(try repository.status(), [
            GitStatusItem(path: "README", index: "?", worktree: "?"),
            GitStatusItem(path: "Sources/main.c", index: "?", worktree: "?"),
        ])
        XCTAssertTrue(try repository.diff().contains("+hello"), "untracked content shows")
        let one = try repository.diff(path: "README")
        XCTAssertTrue(one.contains("+hello") && !one.contains("main.c"), one)

        try repository.stage(["README", "Sources/main.c"])
        XCTAssertEqual(try repository.status().map(\.index), ["A", "A"])
        let staged = try repository.diff(staged: true)
        XCTAssertTrue(staged.contains("diff --git a/README b/README"), staged)
        XCTAssertEqual(try repository.diff(), "")

        // Unstaging before the first commit drops the entry.
        try repository.unstage(["README"])
        XCTAssertEqual(try repository.status(), [
            GitStatusItem(path: "README", index: "?", worktree: "?"),
            GitStatusItem(path: "Sources/main.c", index: "A", worktree: " "),
        ])

        let first = try repository.commit(message: "First", author: author)
        XCTAssertEqual(first.count, 40)
        XCTAssertEqual(repository.head(), GitHead(branch: "main", commit: first))
        XCTAssertEqual(try repository.status(), [GitStatusItem(path: "README", index: "?", worktree: "?")])

        XCTAssertThrowsError(try repository.commit(message: "Nothing", author: author)) { XCTAssertEqual(($0 as? GitError)?.kind, .invalid) }
        XCTAssertThrowsError(try repository.commit(message: "   ", author: author))

        try write("int main(void) { return 1; }\n", "Sources/main.c", in: root)
        XCTAssertEqual(try repository.status().first { $0.path == "Sources/main.c" }, GitStatusItem(path: "Sources/main.c", index: " ", worktree: "M"))
        let diff = try repository.diff(path: "Sources/main.c")
        XCTAssertTrue(diff.contains("-int main(void) { return 0; }") && diff.contains("+int main(void) { return 1; }"), diff)
        XCTAssertFalse(diff.contains("README"))

        try repository.stage(["Sources/main.c"])
        XCTAssertEqual(try repository.status().first { $0.path == "Sources/main.c" }?.index, "M")
        try repository.unstage(["Sources/main.c"])
        XCTAssertEqual(try repository.status().first { $0.path == "Sources/main.c" }, GitStatusItem(path: "Sources/main.c", index: " ", worktree: "M"))

        // Staging a deleted file stages its removal.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try repository.stage(["Sources/main.c"])
        XCTAssertEqual(try repository.status().first { $0.path == "Sources/main.c" }?.index, "D")
        let second = try repository.commit(message: "Remove main.c", author: author)
        XCTAssertNotEqual(second, first)
    }

    func testPathsAreLiteralAndInside() throws {
        let (root, repository) = try temporaryRepository()
        try write("a\n", "a*", in: root)
        try write("b\n", "ab", in: root)
        try repository.stage(["a*"])
        XCTAssertEqual(try repository.status().filter { $0.index == "A" }.map(\.path), ["a*"], "a glob is a file name")
        for bad in ["../x", "/etc/passwd", "", ".git/config", "a/../../b"] {
            XCTAssertThrowsError(try repository.stage([bad]), bad.debugDescription)
        }
    }

    func testDoesNotOpenARepositoryAbove() throws {
        let (root, _) = try temporaryRepository()
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GitRepository(at: inner))
    }

    func testShallowCloneRefusesBadInput() throws {
        let (root, _) = try temporaryRepository()
        for branch in ["", "-x", "a..b"] {
            XCTAssertThrowsError(try GitClone.shallow(url: "https://example.invalid/a.git", branch: branch, into: root.appendingPathComponent("c"))) {
                XCTAssertEqual(($0 as? GitError)?.kind, .invalid)
            }
        }
        // libgit2's local transport has no shallow fetch: the network tests
        // below are where a clone is proved.
        XCTAssertThrowsError(try GitClone.shallow(url: root.path, branch: "main", into: root.appendingPathComponent("c")))
    }

    func testRemoteAcceptance() {
        XCTAssertTrue(GitClone.isAcceptedRemote("https://github.com/libgit2/TestGitRepository.git"))
        for url in ["http://github.com/a/b", "git@github.com:a/b.git", "ssh://github.com/a/b", "file:///tmp/x", "https://user:pw@github.com/a/b", "/tmp/x"] {
            XCTAssertFalse(GitClone.isAcceptedRemote(url), url)
        }
    }
}

/// These talk to github.com. Set APELIN_SKIP_NETWORK_TESTS=1 to skip them.
final class GitNetworkTests: XCTestCase {
    static let url = "https://github.com/libgit2/TestGitRepository.git"
    static let branch = "first-merge"
    static let tip = "0966a434eb1a025db6b71485ab63a3bfbea520b6"

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["APELIN_SKIP_NETWORK_TESTS"] != nil, "APELIN_SKIP_NETWORK_TESTS is set")
    }

    private func destination() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("apelin-net-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testShallowCloneOfOneBranch() throws {
        let into = destination()
        var calls = 0
        let result = try GitClone.shallow(url: Self.url, branch: Self.branch, into: into) { _ in
            calls += 1
            return true
        }
        XCTAssertEqual(result, GitCloneResult(commit: Self.tip))
        XCTAssertGreaterThan(calls, 0)
        let repository = try GitRepository(at: into)
        XCTAssertEqual(repository.head(), GitHead(branch: Self.branch, commit: Self.tip))
        XCTAssertEqual(try repository.status(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: into.appendingPathComponent(".git/shallow").path), "depth 1")
        let refs = try FileManager.default.contentsOfDirectory(atPath: into.appendingPathComponent(".git/refs/tags").path)
        XCTAssertEqual(refs, [], "no tags")
    }

    func testCancelFromProgress() throws {
        XCTAssertThrowsError(try GitClone.shallow(url: Self.url, branch: Self.branch, into: destination()) { _ in false }) {
            XCTAssertEqual(($0 as? GitError)?.kind, .cancelled)
        }
    }

    func testListsBranches() throws {
        let branches = try GitRemote.branches(url: Self.url, prefix: "first")
        XCTAssertEqual(branches, ["first-merge"])
    }
}
