import enum ApelinCore.CanonicalPath
import Foundation

public enum PathPolicyError: Error, Equatable, LocalizedError {
    case invalidProjectName(String)
    case embeddedNUL
    case emptyPath
    case rootUnavailable(String)
    case outsideRoot(String)
    case symlinkRefused(String)
    case notFound(String)
    case notAFile(String)
    case notADirectory(String)
    case alreadyExists(String)
    case gitDirectory(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidProjectName(name): "'\(name)' is not a valid project name"
        case .embeddedNUL: "path contains a NUL byte"
        case .emptyPath: "path is empty"
        case let .rootUnavailable(path): "root \(path) is not available"
        case let .outsideRoot(path): "\(path) is outside the project"
        case let .symlinkRefused(path): "\(path) is a symbolic link; it is not written through"
        case let .notFound(path): "\(path) does not exist"
        case let .notAFile(path): "\(path) is not a regular file"
        case let .notADirectory(path): "\(path) is not a directory"
        case let .alreadyExists(path): "\(path) already exists"
        case let .gitDirectory(path):
            "\(path) is in a git directory; the file tools do not write there, the git operations do"
        case let .io(message): message
        }
    }
}

/// A directory that file operations may not leave.
///
/// Every decision is made on canonical paths: `realpath(3)` first, then a
/// component-wise prefix comparison against the root's own realpath. A NUL
/// is rejected before anything else. Writes never follow a symbolic link in
/// the final component, and the parent is re-checked immediately before the
/// file is created. Nothing is written in a repository's git directory.
public struct ScopedRoot: Sendable, Hashable {
    /// The root's realpath.
    public let path: String
    let components: [String]
    /// Called once for each walk of the project for `.git` files
    /// (`GitDirectoryGuard.swift`), so a test can hold a write to one; nil
    /// in the worker. Not part of the root's identity.
    var onGitWalk: (@Sendable () -> Void)?

    public init(_ url: URL) throws {
        let raw = url.path
        guard !CanonicalPath.containsNUL(raw) else { throw PathPolicyError.embeddedNUL }
        guard let real = CanonicalPath.resolve(raw) else { throw PathPolicyError.rootUnavailable(raw) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PathPolicyError.notADirectory(raw)
        }
        path = real
        components = Self.split(real)
    }

    // MARK: - Resolution

    /// The canonical path of an existing item inside the root. `relative` may
    /// also be an absolute path, which must then resolve inside the root.
    public func resolveExisting(_ relative: String) throws -> String {
        let joined = try join(relative)
        guard let real = CanonicalPath.resolve(joined) else { throw PathPolicyError.notFound(relative) }
        guard contains(real) else { throw PathPolicyError.outsideRoot(relative) }
        return real
    }

    /// The path a new or replaced file will have, with every existing
    /// ancestor canonicalised and checked, and the missing remainder made of
    /// plain components only. Refuses a final component that is a symbolic
    /// link or a directory, and a path in a git directory.
    public func resolveForWrite(_ relative: String) throws -> WriteTarget {
        try resolveForWrite(relative, findingGitPointers: true)
    }

    /// As `resolveForWrite(_:)`; without `findingGitPointers` the project
    /// is not walked for `.git` files elsewhere (`GitDirectoryGuard.swift`),
    /// and `commit` walks it instead.
    func resolveForWrite(_ relative: String, findingGitPointers: Bool) throws -> WriteTarget {
        let joined = try join(relative)
        let parts = Self.split(joined)
        guard !parts.isEmpty else { throw PathPolicyError.emptyPath }

        // Longest existing prefix (lstat, so a dangling link still counts as
        // existing and is then canonicalised — or refused — below).
        var existingCount = 0
        for count in stride(from: parts.count, through: 0, by: -1) {
            let candidate = "/" + parts.prefix(count).joined(separator: "/")
            var info = stat()
            if lstat(candidate, &info) == 0 {
                existingCount = count; break
            }
        }
        let existingPrefix = "/" + parts.prefix(existingCount).joined(separator: "/")
        let remainder = Array(parts.dropFirst(existingCount))
        for component in remainder where component == "." || component == ".." {
            throw PathPolicyError.outsideRoot(relative)
        }

        if remainder.isEmpty {
            // The target itself exists.
            var info = stat()
            guard lstat(existingPrefix, &info) == 0 else { throw PathPolicyError.notFound(relative) }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw PathPolicyError.symlinkRefused(relative)
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw PathPolicyError.notAFile(relative) }
            let parent = (existingPrefix as NSString).deletingLastPathComponent
            guard let realParent = CanonicalPath.resolve(parent), contains(realParent) else {
                throw PathPolicyError.outsideRoot(relative)
            }
            let final = (realParent as NSString).appendingPathComponent((existingPrefix as NSString).lastPathComponent)
            guard contains(final) else { throw PathPolicyError.outsideRoot(relative) }
            try refuseGitPath(final, requested: relative)
            return try WriteTarget(
                root: self,
                parent: realParent,
                missingDirectories: [],
                fileName: (final as NSString).lastPathComponent,
                exists: true,
                gitPointers: findingGitPointers ? gitPointers(refusing: final, requested: relative) : nil,
            )
        }

        guard let realExisting = CanonicalPath.resolve(existingPrefix), contains(realExisting) else {
            throw PathPolicyError.outsideRoot(relative)
        }
        var info = stat()
        guard stat(realExisting, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw PathPolicyError.notADirectory(existingPrefix)
        }
        let final = ([realExisting] + remainder).joined(separator: "/")
        try refuseGitPath(final, requested: relative)
        return try WriteTarget(
            root: self,
            parent: realExisting,
            missingDirectories: Array(remainder.dropLast()),
            fileName: remainder.last!,
            exists: false,
            gitPointers: findingGitPointers ? gitPointers(refusing: final, requested: relative) : nil,
        )
    }

    public static func == (lhs: ScopedRoot, rhs: ScopedRoot) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    /// `true` when `canonical` (already a realpath) is the root or below it.
    public func contains(_ canonical: String) -> Bool {
        CanonicalPath.isCanonical(canonical, inside: path)
    }

    /// `canonical` relative to the root, `"."` for the root itself.
    public func relative(_ canonical: String) -> String {
        let parts = Self.split(canonical)
        guard contains(canonical) else { return canonical }
        let rest = parts.dropFirst(components.count)
        return rest.isEmpty ? "." : rest.joined(separator: "/")
    }

    // MARK: - Helpers

    private func join(_ relative: String) throws -> String {
        guard !CanonicalPath.containsNUL(relative) else { throw PathPolicyError.embeddedNUL }
        let trimmed = relative.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return path }
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        if trimmed.hasPrefix("~") {
            throw PathPolicyError.outsideRoot(relative)
        }
        return (path as NSString).appendingPathComponent(trimmed)
    }

    static func split(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

/// A checked destination for a file write. `commit` re-checks the parent,
/// makes the missing directories one level at a time without following a
/// link, writes a temporary file beside the target and renames it into place.
public struct WriteTarget: Sendable {
    public let root: ScopedRoot
    public let parent: String
    public let missingDirectories: [String]
    public let fileName: String
    public let exists: Bool
    /// The project walk `resolveForWrite` made, so `commit` does not walk
    /// again; nil when it was resolved without one.
    let gitPointers: GitPointers?

    public var finalPath: String {
        var path = parent
        for directory in missingDirectories {
            path = (path as NSString).appendingPathComponent(directory)
        }
        return (path as NSString).appendingPathComponent(fileName)
    }

    /// Writes `data`. With `exclusive`, fails if the file appeared meanwhile.
    public func commit(_ data: Data, exclusive: Bool) throws {
        guard let realParent = CanonicalPath.resolve(parent), realParent == parent, root.contains(realParent) else {
            throw PathPolicyError.outsideRoot(parent)
        }
        // The path again here: a .git file may have appeared on it since the
        // target was resolved. The walk's answer is the one resolution made.
        let requested = root.relative(finalPath)
        try root.refuseGitPath(finalPath, requested: requested)
        if let gitPointers {
            try gitPointers.refuse(finalPath, requested: requested)
        } else {
            _ = try root.gitPointers(refusing: finalPath, requested: requested)
        }
        var directory = parent
        for component in missingDirectories {
            directory = (directory as NSString).appendingPathComponent(component)
            if mkdir(directory, 0o755) != 0, errno != EEXIST {
                throw PathPolicyError.io(
                    "could not create \(root.relative(directory)): \(String(cString: strerror(errno)))",
                )
            }
            var info = stat()
            guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw PathPolicyError.symlinkRefused(root.relative(directory))
            }
        }
        let target = (directory as NSString).appendingPathComponent(fileName)

        var mode: mode_t = 0o644
        var existing = stat()
        if lstat(target, &existing) == 0 {
            if exclusive {
                throw PathPolicyError.alreadyExists(root.relative(target))
            }
            if (existing.st_mode & S_IFMT) == S_IFLNK {
                throw PathPolicyError.symlinkRefused(root.relative(target))
            }
            guard (existing.st_mode & S_IFMT) == S_IFREG else { throw PathPolicyError.notAFile(root.relative(target)) }
            mode = existing.st_mode & 0o7777
        }

        let temporary = (directory as NSString).appendingPathComponent(".\(fileName).apelin-\(UUID().uuidString)")
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else {
            throw PathPolicyError.io("could not write \(root.relative(target)): \(String(cString: strerror(errno)))")
        }
        var ok = true
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 {
                    ok = false; return
                }
                offset += written
            }
        }
        if ok {
            fchmod(fd, mode)
        }
        close(fd)
        guard ok else {
            unlink(temporary)
            throw PathPolicyError.io("could not write \(root.relative(target))")
        }
        if exclusive {
            // link(2) fails if the name exists, so creation stays exclusive.
            let linked = link(temporary, target)
            let linkErrno = errno
            unlink(temporary)
            if linked != 0 {
                if linkErrno == EEXIST {
                    throw PathPolicyError.alreadyExists(root.relative(target))
                }
                throw PathPolicyError.io(
                    "could not create \(root.relative(target)): \(String(cString: strerror(linkErrno)))",
                )
            }
        } else if rename(temporary, target) != 0 {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw PathPolicyError.io("could not replace \(root.relative(target)): \(reason)")
        }
    }
}
