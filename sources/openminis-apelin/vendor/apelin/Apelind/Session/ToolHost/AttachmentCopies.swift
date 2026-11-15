import ApelinCore
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation

/// The files `toolHostCall` relays, each way, as copies the host makes: the
/// sender's descriptor is read whole and closed, the bytes go into a file
/// in a root-only directory that is unlinked the moment it is opened, and the
/// receiver gets a read-only descriptor to it. So the receiver never holds
/// the sender's open file (it could write it, or watch it change), no path
/// either side chose is opened, and nothing outlives the last descriptor.
///
/// Bounded: a regular file of at most `maximumBytes`, read to its end. A file
/// that grows past the bound while it is read is refused, not cut.
struct AttachmentCopies: Sendable {
    struct Copy {
        /// Read-only, to a file with no name.
        let descriptor: OwnedDescriptor
        let byteCount: Int
        /// `sha256:<hex>`.
        let sha256: String
    }

    let directory: URL

    /// Removes what a host that died between creating a copy and unlinking
    /// it left behind. Call once, before the first copy.
    func sweep() {
        let path = directory.path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for name in names where name.hasPrefix("attachment.") {
            unlink(path + "/" + name)
        }
    }

    func copy(_ source: Int32, maximumBytes: Int) throws -> Copy {
        var info = stat()
        guard fstat(source, &info) == 0 else {
            throw ApelinError(.badRequest, "an attachment's descriptor is not open")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ApelinError(.badRequest, "an attachment is not a regular file")
        }
        guard info.st_size <= off_t(maximumBytes) else {
            throw ApelinError(
                .badRequest,
                "an attachment is \(info.st_size) bytes, over the \(maximumBytes)-byte limit",
            )
        }

        let (writer, reader) = try create()
        defer { close(writer) }
        do {
            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            var offset = 0
            while true {
                let count = buffer.withUnsafeMutableBytes { pread(source, $0.baseAddress, $0.count, off_t(offset)) }
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ApelinError(.badRequest, "an attachment cannot be read: \(String(cString: strerror(errno)))")
                }
                if count == 0 {
                    break
                }
                guard offset + count <= maximumBytes else {
                    throw ApelinError(
                        .badRequest,
                        "an attachment grew past the \(maximumBytes)-byte limit while it was read",
                    )
                }
                try buffer.withUnsafeBytes { raw in
                    let chunk = UnsafeRawBufferPointer(rebasing: raw[0 ..< count])
                    hash.update(bufferPointer: chunk)
                    var written = 0
                    while written < count {
                        let result = Darwin.write(writer, chunk.baseAddress! + written, count - written)
                        if result < 0 {
                            if errno == EINTR {
                                continue
                            }
                            throw ApelinError(
                                .unavailable,
                                "the attachment copy cannot be written: \(String(cString: strerror(errno)))",
                            )
                        }
                        written += result
                    }
                }
                offset += count
            }
            let digest = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
            return Copy(descriptor: reader, byteCount: offset, sha256: digest)
        } catch {
            reader.close()
            throw error
        }
    }

    /// A new file in `directory`, open for writing and, separately, read-only;
    /// unlinked before either is used.
    private func create() throws -> (Int32, OwnedDescriptor) {
        try prepareDirectory()
        var template = Array((directory.path + "/attachment.XXXXXX").utf8CString)
        let writer = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard writer >= 0 else {
            throw ApelinError(.unavailable, "no attachment copy can be made: \(String(cString: strerror(errno)))")
        }
        let path = String(cString: template)
        let reader = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let failure = errno
        unlink(path)
        guard reader >= 0 else {
            close(writer)
            throw ApelinError(.unavailable, "no attachment copy can be made: \(String(cString: strerror(failure)))")
        }
        _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
        _ = fchmod(writer, 0o400)
        return (writer, OwnedDescriptor(adopting: reader))
    }

    /// `directory` as a real directory of this user's, mode 0700, made if
    /// missing; a symlink or anything else there is refused.
    private func prepareDirectory() throws {
        let path = directory.path
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw ApelinError(.unavailable, "\(path) cannot be made: \(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else {
            throw ApelinError(.unavailable, "\(path) is not a private directory of this process's user")
        }
    }
}
