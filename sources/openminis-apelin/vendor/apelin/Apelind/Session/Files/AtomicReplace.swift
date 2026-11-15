import ApelinProtocol
import Darwin
import Foundation

// Ported from Fila (OwnGoal Studio, MIT): `AtomicSave` and
// `FileOperations.replaceItem`, narrowed to the protected edit's one write —
// the contents of an existing regular file, owner, group, mode, ACLs, xattrs,
// creation time and flags kept.

/// Replaces the contents of an existing regular file without ever truncating
/// it: write a new file beside it (`O_CREAT | O_EXCL | O_NOFOLLOW`, in the
/// directory held open), carry the original's metadata onto it, fsync, then
/// `renameat` over the name. A power cut leaves the old file or the new one,
/// never half of either; a half-written launchd plist is a boot loop.
///
/// Right before the rename the name must still be the file that was granted:
/// same device, inode, size and modification time, so a file replaced or
/// edited since the open is never overwritten.
enum AtomicReplace {
    static func replace(_ path: String, with data: Data, expecting expected: FileVersion) throws -> FileVersion {
        let directoryPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let directory = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw failure("opening \(directoryPath)") }
        defer { close(directory) }

        let existing = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard existing >= 0 else { throw failure("opening \(path)") }
        defer { close(existing) }
        var original = stat()
        guard fstat(existing, &original) == 0 else { throw failure("reading \(path)") }
        guard original.st_mode & S_IFMT == S_IFREG else {
            throw ApelinError(.conflict, "\(path) is no longer a regular file")
        }
        try requireUnchanged(original, expected, path)

        let temporaryName = ".apelin-edit-\(UUID().uuidString)"
        let temporary = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporary >= 0 else { throw failure("creating a temporary beside \(path)") }
        var published = false
        defer {
            close(temporary)
            if !published {
                unlinkat(directory, temporaryName, 0)
            }
        }

        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(temporary, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { throw failure("writing the new contents") }
                written += count
            }
        }

        // ACLs and extended attributes, then owner before mode (chown clears
        // setuid and setgid), then the original's creation time. A
        // filesystem with no creation time refuses it; that loses nothing.
        guard fcopyfile(existing, temporary, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else {
            throw failure("copying attributes")
        }
        if geteuid() == 0 || original.st_uid == geteuid() {
            guard fchown(temporary, original.st_uid, original.st_gid) == 0 else { throw failure("keeping the owner") }
        }
        guard fchmod(temporary, original.st_mode & 0o7777) == 0 else { throw failure("keeping the mode") }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var created = original.st_birthtimespec
        _ = fsetattrlist(temporary, &request, &created, MemoryLayout<timespec>.size, 0)

        while fsync(temporary) != 0 {
            guard errno == EINTR else { throw failure("flushing the new contents") }
        }

        // The last look before the swap.
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("checking \(path)") }
        guard current.st_mode & S_IFMT == S_IFREG else {
            throw ApelinError(.conflict, "\(path) is no longer a regular file")
        }
        try requireUnchanged(current, expected, path)

        guard renameat(directory, temporaryName, directory, name) == 0 else { throw failure("replacing \(path)") }
        published = true
        if original.st_flags != 0 {
            _ = fchflags(temporary, original.st_flags)
        }

        var after = stat()
        guard fstat(temporary, &after) == 0 else { throw failure("reading the new \(path)") }
        return ProtectedEditPolicy.version(after, sha256: ProtectedEditPolicy.sha256(data))
    }

    private static func requireUnchanged(_ metadata: stat, _ expected: FileVersion, _ path: String) throws {
        let now = ProtectedEditPolicy.version(metadata, sha256: nil)
        guard now.device == expected.device, now.inode == expected.inode, now.size == expected.size,
              abs(now.modified - expected.modified) < 0.000_001
        else {
            throw ApelinError(.conflict, "\(path) changed after it was opened; open it again")
        }
    }

    private static func failure(_ step: String) -> ApelinError {
        ApelinError(.internal, "\(step): \(String(cString: strerror(errno)))")
    }
}
