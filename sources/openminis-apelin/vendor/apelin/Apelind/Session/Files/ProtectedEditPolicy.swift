import ApelinCore
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation

/// What the app's manual protected edit may touch (Milestone 1 §2, 编辑范围):
/// the contents of an existing regular file inside the bootstrap install
/// root, and nothing else — no creating, deleting, renaming, re-owning or
/// changing modes. Any mistake must be at worst one reversible replacement.
///
/// Refused: a path outside the install root (canonical, compared by
/// components), a symlink at the picked path, a hard-linked file, a file with
/// any execute bit, a Mach-O, anything over `maximumBytes`, and the package
/// managers' and Apelin's own records (`var/lib/dpkg`, `var/lib/apt`,
/// `var/lib/irisin`, `var/lib/apelin`). A LaunchDaemons plist is allowed but
/// needs the save's explicit confirmation.
enum ProtectedEditPolicy {
    static let maximumBytes = 8 << 20

    /// Relative to the install root; every file below each is refused.
    static let refusedTrees = [
        "var/lib/dpkg", "var/lib/apt", "var/cache/apt", "var/lib/irisin", "var/lib/apelin",
        "Library/dpkg", "etc/apt/trusted.gpg.d",
    ]

    struct Target: Equatable {
        /// Canonical.
        var path: String
        var version: FileVersion
        var needsConfirmation: Bool
    }

    /// Checks `path` and answers the file it names, with its current version
    /// (the SHA-256 of its contents included).
    static func evaluate(_ path: String, installRoot: String) throws -> Target {
        guard !CanonicalPath.containsNUL(path) else { throw ApelinError(.badRequest, "the path contains a NUL byte") }
        guard path.hasPrefix("/") else { throw ApelinError(.badRequest, "a protected edit takes an absolute path") }
        var linkCheck = stat()
        guard lstat(path, &linkCheck) == 0 else {
            throw ApelinError(.notFound, "\(path): \(String(cString: strerror(errno)))")
        }
        guard linkCheck.st_mode & S_IFMT != S_IFLNK else {
            throw ApelinError(.denied, "\(path) is a symbolic link; open the file it points to")
        }
        guard let canonical = CanonicalPath.resolve(path), let root = CanonicalPath.resolve(installRoot) else {
            throw ApelinError(.notFound, "\(path) does not resolve")
        }
        guard CanonicalPath.isCanonical(canonical, inside: root), canonical != root else {
            throw ApelinError(.denied, "a protected edit stays inside the bootstrap's install root (\(root))")
        }
        let relative = CanonicalPath.components(String(canonical.dropFirst(root.count == 1 ? 0 : root.count)))
        for tree in refusedTrees {
            let parts = CanonicalPath.components(tree)
            if relative.count >= parts.count, zip(relative, parts).allSatisfy({ $0 == $1 }) {
                throw ApelinError(.denied, "\(canonical) is a package manager's or Apelin's own record")
            }
        }

        let descriptor = open(canonical, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ApelinError(.denied, "\(canonical): \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        return try evaluate(descriptor: descriptor, canonical: canonical, relative: relative.map(String.init))
    }

    static func evaluate(descriptor: Int32, canonical: String, relative: [String]) throws -> Target {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw ApelinError(.internal, String(cString: strerror(errno))) }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw ApelinError(.denied, "\(canonical) is not a regular file")
        }
        guard metadata.st_nlink <= 1 else {
            throw ApelinError(
                .denied,
                "\(canonical) has \(metadata.st_nlink) hard links; replacing it would split them",
            )
        }
        guard metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) == 0 else {
            throw ApelinError(.denied, "\(canonical) is executable and cannot be edited here.")
        }
        guard metadata.st_size <= maximumBytes else {
            throw ApelinError(.denied, "\(canonical) is too large to edit here.")
        }
        var magic = [UInt8](repeating: 0, count: 4)
        if pread(descriptor, &magic, 4, 0) == 4, isMachO(magic) {
            throw ApelinError(.denied, "\(canonical) is a Mach-O binary")
        }
        let digest = try sha256(descriptor: descriptor)
        let needsConfirmation = relative.count >= 3
            && relative[relative.count - 3] == "Library" && relative[relative.count - 2] == "LaunchDaemons"
            && canonical.hasSuffix(".plist")
        return Target(
            path: canonical,
            version: version(metadata, sha256: digest),
            needsConfirmation: needsConfirmation,
        )
    }

    static func isMachO(_ magic: [UInt8]) -> Bool {
        let known: [[UInt8]] = [
            [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA], [0xCA, 0xFE, 0xBA, 0xBF], [0xBF, 0xBA, 0xFE, 0xCA],
        ]
        return known.contains(magic)
    }

    static func version(_ metadata: stat, sha256: String?) -> FileVersion {
        FileVersion(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino),
            size: Int64(metadata.st_size),
            modified: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000,
            sha256: sha256,
        )
    }

    static func sha256(descriptor: Int32) throws -> String {
        var hash = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, offset) }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw ApelinError(.internal, String(cString: strerror(errno))) }
            if count == 0 {
                break
            }
            hash.update(data: buffer[0 ..< count])
            offset += off_t(count)
        }
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
