import ApelinCore
import ApelinProtocol
import ArchiveKit
import CryptoKit
import Darwin
import Foundation

/// The bounds every transfer file is read within.
public struct TransferLimits: Sendable {
    public var manifestBytes: Int
    public var payloadBytes: Int64
    public var members: Int
    public var depth: Int

    public init(
        manifestBytes: Int = 64 << 20,
        payloadBytes: Int64 = 32 << 30,
        members: Int = 1_000_000,
        depth: Int = 64,
    ) {
        self.manifestBytes = manifestBytes
        self.payloadBytes = payloadBytes
        self.members = members
        self.depth = depth
    }
}

/// Writes a transfer file: a pax tar through zstd, `manifest.json` first,
/// then every member as `payload/<path>` in the manifest's order. Owner and
/// times are not carried: a file is its bytes and its execute bit. Each file
/// is hashed again as it is written; one that changed since the manifest was
/// made fails the export.
struct TransferArchiveWriter {
    var root: URL
    /// Where each file member's bytes are read from, by member path.
    var sources: [String: URL]

    func write(_ manifest: TransferManifest, to destination: URL, reporter: TaskReporter) throws {
        reporter.progress("packing", completed: 0, total: manifest.payloadBytes)
        guard let archive = archive_write_new() else { throw ApelinError(.internal, "archive_write_new failed") }
        defer { archive_write_free(archive) }
        try check(archive, archive_write_set_format_pax_restricted(archive), "choose the tar format")
        try check(archive, archive_write_add_filter_zstd(archive), "choose zstd")
        try check(archive, archive_write_set_bytes_per_block(archive, 0), "set the block size")
        try check(
            archive,
            archive_write_open_filename(archive, destination.path),
            "create \(destination.lastPathComponent)",
        )

        try ArchiveExtractor.withUTF8Names {
            let manifestData = try JSONCoding.encoder(pretty: true).encode(manifest)
            try header(archive, TransferManifest.fileName, type: S_IFREG, mode: 0o644, size: Int64(manifestData.count))
            try writeData(archive, manifestData)

            let total = manifest.payloadBytes
            var written: Int64 = 0
            let throttle = ProgressThrottle()
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
            defer { buffer.deallocate() }
            for member in manifest.members {
                try reporter.checkCancelled()
                let name = TransferManifest.payloadPrefix + member.path
                switch member.kind {
                case .directory:
                    try header(archive, name, type: S_IFDIR, mode: 0o755, size: 0)
                case .link:
                    try header(archive, name, type: S_IFLNK, mode: 0o755, size: 0, link: member.target)
                case .file:
                    guard let source = sources[member.path], let size = member.size else {
                        throw ApelinError(.internal, "no source for \(member.path)")
                    }
                    try header(
                        archive,
                        name,
                        type: S_IFREG,
                        mode: member.executable == true ? 0o755 : 0o644,
                        size: size,
                    )
                    let descriptor = try TransferDigest.openFile(source, inside: root)
                    defer { close(descriptor) }
                    var hash = SHA256()
                    var count: Int64 = 0
                    while true {
                        let read = Darwin.read(descriptor, buffer, 1 << 20)
                        guard read >= 0 else { throw ArchiveExtractor.posix("read \(member.path)") }
                        if read == 0 {
                            break
                        }
                        count += Int64(read)
                        guard count <= size else { break }
                        hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: read))
                        try writeData(archive, UnsafeRawBufferPointer(start: buffer, count: read))
                        written += Int64(read)
                        if throttle.shouldEmit() {
                            reporter.progress("packing", completed: written, total: total, detail: member.path)
                        }
                        try reporter.checkCancelled()
                    }
                    guard count == size, TransferDigest.hex(hash.finalize()) == member.sha256 else {
                        throw ApelinError(
                            .conflict,
                            "\(member.path) changed while it was being exported; export it again",
                        )
                    }
                }
            }
            reporter.progress("packing", completed: written, total: total, detail: "\(manifest.members.count) members")
        }
        try check(archive, archive_write_close(archive), "finish \(destination.lastPathComponent)")
    }

    private func header(
        _ archive: OpaquePointer,
        _ name: String,
        type: mode_t,
        mode: mode_t,
        size: Int64,
        link: String? = nil,
    ) throws {
        guard let entry = archive_entry_new() else { throw ApelinError(.internal, "archive_entry_new failed") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_filetype(entry, UInt32(type))
        archive_entry_set_perm(entry, mode)
        archive_entry_set_size(entry, size)
        archive_entry_set_uid(entry, 0)
        archive_entry_set_gid(entry, 0)
        archive_entry_set_mtime(entry, 0, 0)
        if let link {
            archive_entry_set_symlink_utf8(entry, link)
        }
        try check(archive, archive_write_header(archive, entry), "write \(name)")
    }

    private func writeData(_ archive: OpaquePointer, _ data: Data) throws {
        try data.withUnsafeBytes { try writeData(archive, $0) }
    }

    private func writeData(_ archive: OpaquePointer, _ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        var done = 0
        while done < bytes.count {
            let wrote = archive_write_data(archive, base + done, bytes.count - done)
            guard wrote > 0 else { throw failure(archive, "write the archive") }
            done += wrote
        }
    }

    private func check(_ archive: OpaquePointer, _ status: Int32, _ what: String) throws {
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN else { throw failure(archive, what) }
    }

    private func failure(_ archive: OpaquePointer, _ what: String) -> ApelinError {
        let message = archive_error_string(archive).map { String(cString: $0) } ?? "libarchive error"
        return ApelinError(.internal, "\(what): \(message)")
    }
}

/// Reads a transfer file, never through `archive_read_extract`:
///
/// - the first member is `manifest.json`, at most `manifestBytes`, read and
///   checked whole (`TransferArchiveReader.check`) before anything else;
/// - every other member is `payload/<path>` of a member the manifest lists,
///   of the kind it lists, each at most once, with no NUL, absolute name,
///   `..` or name too deep;
/// - every folder on the way is made here and checked with `lstat`, so a
///   link member cannot redirect a later file; files are created
///   `O_EXCL | O_NOFOLLOW`, 0755 or 0644, never set-id;
/// - a file's size and SHA-256 must be the manifest's, a link's target
///   must be the manifest's (relative and staying inside the payload);
/// - hard links, devices, FIFOs and sockets are refused;
/// - a member the manifest lists and the file lacks fails the read.
struct TransferArchiveReader {
    var limits = TransferLimits()

    /// Reads `manifest.json` alone.
    func manifest(_ input: ArchiveExtractor.Input) throws -> TransferManifest {
        try withArchive(input) { archive in try readManifest(archive) }
    }

    /// Unpacks the payload into `destination` (existing, empty) and answers
    /// the manifest it was checked against.
    func extract(
        _ input: ArchiveExtractor.Input,
        into destination: URL,
        reporter: TaskReporter,
    ) throws -> TransferManifest {
        try withArchive(input) { archive in
            let manifest = try readManifest(archive)
            try payload(archive, manifest: manifest, into: destination.standardizedFileURL, reporter: reporter)
            return manifest
        }
    }

    private func withArchive<T>(_ input: ArchiveExtractor.Input, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let archive = archive_read_new() else { throw ApelinError(.internal, "archive_read_new failed") }
        defer { archive_read_free(archive) }
        archive_read_support_filter_zstd(archive)
        archive_read_support_format_tar(archive)
        let status: Int32
        switch input {
        case let .path(path):
            status = archive_read_open_filename(archive, path, 1 << 20)
        case let .descriptor(descriptor):
            // Every read starts at the beginning: the app's descriptor may
            // share its offset with one an earlier read moved.
            guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw ArchiveExtractor.posix("rewind the file") }
            status = archive_read_open_fd(archive, descriptor, 1 << 20)
        }
        guard status == ARCHIVE_OK else { throw failure(archive, "open the file") }
        return try ArchiveExtractor.withUTF8Names { try body(archive) }
    }

    private func readManifest(_ archive: OpaquePointer) throws -> TransferManifest {
        var entry: OpaquePointer?
        let status = archive_read_next_header(archive, &entry)
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry,
              Self.name(of: entry) == TransferManifest.fileName, archive_entry_filetype(entry) == S_IFREG
        else {
            throw ApelinError(.badRequest, "This is not an Apelin transfer file. Choose another file.")
        }
        let size = archive_entry_size(entry)
        guard size > 0, size <= Int64(limits.manifestBytes) else {
            throw ApelinError(.badRequest, "This file is damaged. Export it again.")
        }
        var data = Data(count: Int(size))
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < raw.count {
                let read = archive_read_data(archive, raw.baseAddress! + offset, raw.count - offset)
                guard read > 0 else { throw failure(archive, "read \(TransferManifest.fileName)") }
                offset += read
            }
        }
        let manifest: TransferManifest
        do {
            manifest = try JSONCoding.decode(TransferManifest.self, from: data)
        } catch {
            throw ApelinError(.badRequest, "This file is damaged. Export it again.")
        }
        try Self.check(manifest, limits: limits)
        return manifest
    }

    /// The manifest's own rules, before any payload is read.
    static func check(_ manifest: TransferManifest, limits: TransferLimits) throws {
        guard manifest.formatVersion <= TransferManifest.currentFormatVersion else {
            throw ApelinError(.badRequest, "This file was made by a newer version of Apelin. Update Apelin to open it.")
        }
        guard manifest.formatVersion >= 1 else {
            throw ApelinError(.badRequest, "Apelin cannot open this file. Export it again.")
        }
        guard !manifest.id.isEmpty, !CanonicalPath.containsNUL(manifest.id), !manifest.name.isEmpty else {
            throw ApelinError(.badRequest, "The file is missing its name or identifier. Export it again.")
        }
        switch manifest.kind {
        case .toolchain:
            guard manifest.toolchain != nil else {
                throw ApelinError(
                    .badRequest,
                    "The file is missing its toolchain information. Export the toolchain again.",
                )
            }
        case .sdk:
            guard manifest.sdk != nil else {
                throw ApelinError(.badRequest, "The file is missing its SDK information. Export the SDK again.")
            }
        case .project:
            guard manifest.project != nil else {
                throw ApelinError(
                    .badRequest,
                    "The file is missing its project information. Export the project again.",
                )
            }
        }
        guard manifest.members.count <= limits.members else {
            throw ApelinError(.badRequest, "the file has more than \(limits.members) members")
        }
        var seen = Set<String>()
        var links: [[String]: String] = [:]
        var total: Int64 = 0
        for member in manifest.members {
            let components = try ArchiveExtractor.components(of: member.path, maximumDepth: limits.depth)
            guard !components.isEmpty, components.joined(separator: "/") == member.path else {
                throw ApelinError(.badRequest, "\(member.path.debugDescription) is not a plain path")
            }
            // Folded: two names APFS takes for one would land on one file.
            guard seen.insert(member.path.lowercased()).inserted else {
                throw ApelinError(.badRequest, "\(member.path) is listed twice")
            }
            switch member.kind {
            case .directory:
                break
            case .file:
                guard let size = member.size, size >= 0, let digest = member.sha256, TransferDigest.isHex(digest) else {
                    throw ApelinError(.badRequest, "\(member.path) has no size or digest")
                }
                total += size
                guard total <= limits.payloadBytes else {
                    throw ApelinError(.badRequest, "the file unpacks to more than \(limits.payloadBytes) bytes")
                }
            case .link:
                guard let target = member.target, !target.isEmpty, !target.hasPrefix("/"),
                      !CanonicalPath.containsNUL(target)
                else {
                    throw ApelinError(.badRequest, "\(member.path) is a link with a bad target")
                }
                links[components] = target
            }
        }
        for components in links.keys where !ToolchainPackager.staysInside(components, links: links) {
            throw ApelinError(.badRequest, "\(components.joined(separator: "/")) links outside the file's contents")
        }
    }

    private func payload(
        _ archive: OpaquePointer,
        manifest: TransferManifest,
        into root: URL,
        reporter: TaskReporter,
    ) throws {
        var expected: [String: TransferMember] = [:]
        for member in manifest.members {
            expected[member.path] = member
        }
        let total = manifest.payloadBytes
        var written: Int64 = 0
        let throttle = ProgressThrottle()
        let extractor = ArchiveExtractor()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }

        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF {
                break
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else {
                throw failure(archive, "read the file")
            }
            try reporter.checkCancelled()
            guard let name = Self.name(of: entry), name.hasPrefix(TransferManifest.payloadPrefix) else {
                throw ApelinError(
                    .badRequest,
                    "the file carries \(Self.name(of: entry) ?? "a nameless member"), outside its payload",
                )
            }
            let path = String(name.dropFirst(TransferManifest.payloadPrefix.count))
            let components = try ArchiveExtractor.components(of: path, maximumDepth: limits.depth)
            let relative = components.joined(separator: "/")
            guard let member = expected.removeValue(forKey: relative) else {
                throw ApelinError(
                    .badRequest,
                    "the file carries \(relative), which its manifest does not list (or lists once)",
                )
            }
            guard archive_entry_hardlink(entry) == nil, archive_entry_hardlink_utf8(entry) == nil else {
                throw ApelinError(.badRequest, "\(relative) is a hard link")
            }
            let type = archive_entry_filetype(entry)
            switch member.kind {
            case .directory:
                guard type == S_IFDIR else {
                    throw ApelinError(.badRequest, "\(relative) is not the folder the manifest lists")
                }
                _ = try extractor.makeDirectories(components, under: root)
            case .link:
                guard type == S_IFLNK else {
                    throw ApelinError(.badRequest, "\(relative) is not the link the manifest lists")
                }
                let target = (archive_entry_symlink_utf8(entry) ?? archive_entry_symlink(entry))
                    .map { String(cString: $0) }
                guard target == member.target, let target else {
                    throw ApelinError(.badRequest, "\(relative) does not link where the manifest says")
                }
                let parent = try extractor.makeDirectories(Array(components.dropLast()), under: root)
                guard symlink(target, parent.appendingPathComponent(components.last!).path) == 0 else {
                    throw ArchiveExtractor.posix("link \(relative)")
                }
            case .file:
                guard type == S_IFREG, let size = member.size, archive_entry_size(entry) == size else {
                    throw ApelinError(.badRequest, "\(relative) is not the file the manifest lists")
                }
                let parent = try extractor.makeDirectories(Array(components.dropLast()), under: root)
                let target = parent.appendingPathComponent(components.last!)
                let descriptor = open(
                    target.path,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    member.executable == true ? 0o755 : 0o644,
                )
                guard descriptor >= 0 else { throw ArchiveExtractor.posix("create \(relative)") }
                defer { close(descriptor) }
                var hash = SHA256()
                var count: Int64 = 0
                while true {
                    let read = archive_read_data(archive, buffer, 1 << 20)
                    if read == 0 {
                        break
                    }
                    guard read > 0 else { throw failure(archive, "read \(relative)") }
                    count += Int64(read)
                    guard count <= size else {
                        throw ApelinError(.badRequest, "\(relative) is longer than the manifest says")
                    }
                    hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: read))
                    var offset = 0
                    while offset < read {
                        let wrote = Darwin.write(descriptor, buffer + offset, read - offset)
                        guard wrote > 0 else { throw ArchiveExtractor.posix("write \(relative)") }
                        offset += wrote
                    }
                    written += Int64(read)
                    if throttle.shouldEmit() {
                        reporter.progress("reading", completed: written, total: total, detail: relative)
                    }
                    try reporter.checkCancelled()
                }
                guard count == size, TransferDigest.hex(hash.finalize()) == member.sha256 else {
                    throw ApelinError(
                        .badRequest,
                        "This file is damaged or was changed after it was exported (\(relative)). Export it again.",
                    )
                }
            }
        }
        if let missing = expected.keys.sorted().first {
            throw ApelinError(.badRequest, "the file lacks \(missing), which its manifest lists")
        }
        reporter.progress("reading", completed: written, total: total, detail: "\(manifest.members.count) members")
    }

    private static func name(of entry: OpaquePointer) -> String? {
        (archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)).map { String(cString: $0) }
    }

    private func failure(_ archive: OpaquePointer, _ what: String) -> ApelinError {
        let message = archive_error_string(archive).map { String(cString: $0) } ?? "libarchive error"
        return ApelinError(.badRequest, "\(what): \(message)")
    }
}

enum TransferDigest {
    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isHex(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    /// SHA-256 and size of a file, read without following a link.
    static func file(
        _ url: URL,
        inside root: URL? = nil,
        progress: (Int64) throws -> Void = { _ in },
    ) throws -> (sha256: String, size: Int64) {
        let descriptor = try openFile(url, inside: root)
        defer { close(descriptor) }
        var hash = SHA256()
        var size: Int64 = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let read = Darwin.read(descriptor, buffer, 1 << 20)
            guard read >= 0 else { throw ArchiveExtractor.posix("read \(url.lastPathComponent)") }
            if read == 0 {
                break
            }
            size += Int64(read)
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: read))
            try progress(size)
        }
        return (hex(hash.finalize()), size)
    }

    /// A directory can change between scanning, hashing and packing. Check
    /// the opened file's actual path, not just the path that named it.
    static func openFile(_ url: URL, inside root: URL?) throws -> Int32 {
        guard !CanonicalPath.containsNUL(url.path) else { throw ApelinError(.badRequest, "a file path contains NUL") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ArchiveExtractor.posix("open \(url.lastPathComponent)") }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw ApelinError(.conflict, "\(url.lastPathComponent) is no longer a regular file")
            }
            if let root {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(descriptor, F_GETPATH, &path) == 0,
                      let canonical = CanonicalPath.resolve(String(cString: path)),
                      CanonicalPath.isCanonical(canonical, inside: root.path)
                else {
                    throw ApelinError(.conflict, "\(url.lastPathComponent) moved outside the export folder")
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }
}
