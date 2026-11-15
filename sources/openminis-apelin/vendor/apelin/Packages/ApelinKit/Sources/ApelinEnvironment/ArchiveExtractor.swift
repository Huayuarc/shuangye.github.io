import ApelinCore
import ApelinProtocol
import ArchiveKit
import Darwin
import Foundation

/// Unpacks a zip, tar.xz, tar.zst (or any tar libarchive reads through any
/// filter) into a staging folder, entry by entry and never through
/// `archive_read_extract`, so every rule is Apelin's:
///
/// - a name with NUL, an absolute name, `..`, or a name that appears twice is
///   refused;
/// - every directory on the way is made here and checked with `lstat`, so
///   an earlier symlink entry cannot redirect a later file (`a -> /etc`,
///   then `a/passwd`);
/// - files are created `O_EXCL | O_NOFOLLOW`, with no set-id or sticky bit;
/// - a symlink is written as it is — the SDK inspection resolves it later and
///   refuses one that leads out; a hard link must name an earlier file;
/// - devices, FIFOs and sockets are refused;
/// - total size and entry count are bounded.
public struct ArchiveExtractor: Sendable {
    public struct Limits: Sendable {
        public var maximumBytes: Int64
        public var maximumEntries: Int
        public var maximumDepth: Int

        public init(maximumBytes: Int64 = 16 << 30, maximumEntries: Int = 1_000_000, maximumDepth: Int = 64) {
            self.maximumBytes = maximumBytes
            self.maximumEntries = maximumEntries
            self.maximumDepth = maximumDepth
        }
    }

    public enum Input: Sendable {
        case path(String)
        case descriptor(Int32)
    }

    public var limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Unpacks `input` into `destination`, which must exist and be empty.
    /// Returns the number of entries written.
    @discardableResult
    public func extract(_ input: Input, into destination: URL, reporter: TaskReporter = .silent) throws -> Int {
        guard let archive = archive_read_new() else { throw ApelinError(.internal, "archive_read_new failed") }
        defer { archive_read_free(archive) }
        archive_read_support_filter_all(archive)
        archive_read_support_format_tar(archive)
        archive_read_support_format_zip(archive)
        archive_read_support_format_cpio(archive)

        let status: Int32 = switch input {
        case let .path(path): archive_read_open_filename(archive, path, 1 << 20)
        case let .descriptor(descriptor): archive_read_open_fd(archive, descriptor, 1 << 20)
        }
        guard status == ARCHIVE_OK else { throw failure(archive, "open the archive") }

        return try Self.withUTF8Names {
            try walk(archive, into: destination.standardizedFileURL, reporter: reporter)
        }
    }

    private func walk(_ archive: OpaquePointer, into root: URL, reporter: TaskReporter) throws -> Int {
        var seen = Set<String>()
        var written: Int64 = 0
        var count = 0
        let throttle = ProgressThrottle()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }

        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF {
                break
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else {
                throw failure(archive, "read the archive")
            }
            try reporter.checkCancelled()

            let rawName = archive_entry_pathname_utf8(entry).map { String(cString: $0) }
                ?? archive_entry_pathname(entry).map { String(cString: $0) }
            guard let rawName else { throw ApelinError(.badRequest, "an archive entry has no name") }
            let components = try Self.components(of: rawName, maximumDepth: limits.maximumDepth)
            if components.isEmpty {
                continue
            }
            let relative = components.joined(separator: "/")
            guard seen.insert(relative).inserted else {
                throw ApelinError(.badRequest, "\(relative) appears twice in the archive")
            }
            count += 1
            guard count <= limits.maximumEntries else {
                throw ApelinError(.badRequest, "the archive has more than \(limits.maximumEntries) entries")
            }

            let parent = try makeDirectories(Array(components.dropLast()), under: root)
            let target = parent.appendingPathComponent(components.last!)

            if let hardlink = archive_entry_hardlink_utf8(entry) ?? archive_entry_hardlink(entry) {
                let linkComponents = try Self.components(
                    of: String(cString: hardlink),
                    maximumDepth: limits.maximumDepth,
                )
                let linked = linkComponents.joined(separator: "/")
                guard seen.contains(linked) else {
                    throw ApelinError(.badRequest, "\(relative) links to \(linked), which comes later or not at all")
                }
                var metadata = stat()
                let source = root.appendingPathComponent(linked).path
                guard lstat(source, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                    throw ApelinError(.badRequest, "\(relative) links to \(linked), which is not a file")
                }
                guard link(source, target.path) == 0 else { throw Self.posix("link \(relative)") }
                continue
            }

            switch archive_entry_filetype(entry) {
            case S_IFDIR:
                _ = try makeDirectories(components, under: root)
            case S_IFLNK:
                guard let pointer = archive_entry_symlink_utf8(entry) ?? archive_entry_symlink(entry) else {
                    throw ApelinError(.badRequest, "\(relative) is a link with no target")
                }
                let destination = String(cString: pointer)
                guard !destination.isEmpty, !CanonicalPath.containsNUL(destination) else {
                    throw ApelinError(.badRequest, "\(relative) is a link with a bad target")
                }
                guard symlink(destination, target.path) == 0 else { throw Self.posix("link \(relative)") }
            case S_IFREG:
                let size = archive_entry_size(entry)
                guard size >= 0, written + size <= limits.maximumBytes else {
                    throw ApelinError(.badRequest, "the archive unpacks to more than \(limits.maximumBytes) bytes")
                }
                let executable = archive_entry_perm(entry) & 0o111 != 0
                let descriptor = open(
                    target.path,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    executable ? 0o755 : 0o644,
                )
                guard descriptor >= 0 else { throw Self.posix("create \(relative)") }
                defer { close(descriptor) }
                var fileBytes: Int64 = 0
                while true {
                    let read = archive_read_data(archive, buffer, 1 << 20)
                    if read == 0 {
                        break
                    }
                    guard read > 0 else { throw failure(archive, "read \(relative)") }
                    fileBytes += Int64(read)
                    guard written + fileBytes <= limits.maximumBytes else {
                        throw ApelinError(.badRequest, "the archive unpacks to more than \(limits.maximumBytes) bytes")
                    }
                    var offset = 0
                    while offset < read {
                        let wrote = Darwin.write(descriptor, buffer + offset, read - offset)
                        guard wrote > 0 else { throw Self.posix("write \(relative)") }
                        offset += wrote
                    }
                    try reporter.checkCancelled()
                }
                written += fileBytes
                if throttle.shouldEmit() {
                    reporter.progress("extracting", completed: written, detail: relative)
                }
            default:
                throw ApelinError(.badRequest, "\(relative) is a device, FIFO or socket")
            }
        }
        reporter.progress("extracting", completed: written, detail: "\(count) entries")
        return count
    }

    /// Makes each directory below `root`, checking every level with `lstat`:
    /// a level that exists must be a real directory, never a symlink.
    func makeDirectories(_ components: [String], under root: URL) throws -> URL {
        var current = root
        for component in components {
            current = current.appendingPathComponent(component, isDirectory: true)
            var metadata = stat()
            if lstat(current.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw ApelinError(
                        .badRequest,
                        "\(component) in the archive is a link or file where a folder is needed",
                    )
                }
                continue
            }
            guard mkdir(current.path, 0o755) == 0 else { throw Self.posix("make \(component)") }
        }
        return current
    }

    /// An entry name as components: no NUL, no `..`, no absolute path
    /// (a leading `./` is fine), at most `maximumDepth` deep.
    static func components(of name: String, maximumDepth: Int) throws -> [String] {
        guard !CanonicalPath.containsNUL(name) else {
            throw ApelinError(.badRequest, "an archive entry name has a NUL")
        }
        guard !name.hasPrefix("/") else { throw ApelinError(.badRequest, "\(name) is an absolute path") }
        let components = CanonicalPath.components(name).map(String.init)
        guard !components.contains("..") else { throw ApelinError(.badRequest, "\(name) leads outside the archive") }
        guard components.count <= maximumDepth else { throw ApelinError(.badRequest, "\(name) is nested too deep") }
        return components
    }

    private func failure(_ archive: OpaquePointer, _ what: String) -> ApelinError {
        let message = archive_error_string(archive).map { String(cString: $0) } ?? "libarchive error"
        return ApelinError(.badRequest, "\(what): \(message)")
    }

    static func posix(_ what: String) -> ApelinError {
        ApelinError(.internal, "\(what): \(String(cString: strerror(errno)))")
    }

    /// libarchive converts names into the thread's codeset; a UTF-8 LC_CTYPE
    /// on this thread only, as ApelinDebArchive does.
    static func withUTF8Names<T>(_ body: () throws -> T) rethrows -> T {
        let previous = uselocale(nil)
        guard let base = duplocale(previous) else { return try body() }
        guard let utf8 = newlocale(LC_CTYPE_MASK, "UTF-8", base) else {
            freelocale(base)
            return try body()
        }
        uselocale(utf8)
        defer {
            uselocale(previous)
            freelocale(utf8)
        }
        return try body()
    }
}
