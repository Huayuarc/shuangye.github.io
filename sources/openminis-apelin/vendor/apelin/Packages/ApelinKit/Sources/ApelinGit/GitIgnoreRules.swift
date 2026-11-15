internal import GitKit
import ApelinCore
import Foundation

/// Git's own ignore matcher, applied one path at a time while exporting.
/// Tracked files and their parent folders survive ignore rules, just as
/// they do in Git. No status walk runs ahead of the cancellable export walk.
public final class GitIgnoreRules {
    private let repository: GitRepository
    private let index: OpaquePointer

    /// With no repository, an empty index lives in the task's staging
    /// folder. Setting its workdir only in memory lets libgit2 read nested
    /// `.gitignore` files without creating or changing anything in `root`.
    public init(root: URL, repository: GitRepository?, scratch: URL) throws {
        let repository = try repository ?? GitRepository.create(at: scratch)
        if repository.workdir != root {
            try GitError.check(
                git_repository_set_workdir(repository.pointer, root.path, 0),
                "read the project's ignore rules",
            )
        }
        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, repository.pointer), "read the tracked files")
        guard let index else { throw GitError(.invalid, "the repository has no index") }
        self.repository = repository
        self.index = index
    }

    deinit { git_index_free(index) }

    public func ignores(_ path: String, isDirectory: Bool) throws -> Bool {
        guard CanonicalPath.isPlainRelative(path) else {
            throw GitError(.invalid, "\(path.debugDescription) is not a path inside the work tree")
        }
        let tracked = isDirectory
            ? git_index_find_prefix(nil, index, path + "/")
            : git_index_find(nil, index, path)
        if tracked == 0 {
            return false
        }
        guard tracked == GIT_ENOTFOUND.rawValue else {
            try GitError.check(tracked, "find the tracked path")
            return false
        }
        var ignored: Int32 = 0
        try GitError.check(
            git_ignore_path_is_ignored(&ignored, repository.pointer, path),
            "read the ignore rules for \(path)",
        )
        return ignored != 0
    }
}
