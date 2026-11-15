// Adapted from Irisin (MIT, OwnGoal Studio):
// Packages/AptRepository/Sources/AptRepository/Helper/ArchiveStream.swift and
// the member checks of ArchiveStream+Preparation.swift (debian-binary must be
// "2.0\n"; control.tar and data.tar exactly once; no path twice). Changed
// here: a package can be read from memory as well as from a path; the
// listing carries each entry's type, mode, owner, size, time and link
// target, and optionally the bytes of small files; members are checked in
// the order dpkg requires.

import ApelinDebian
import ArchiveKit
import Foundation

/// libarchive over the shapes Apelin reads: the `control` member of a `.deb`,
/// a `.deb`'s full listing, and any compressed stream.
///
/// One library for every filter (gzip, bzip2, xz, lzma, zstd, lz4) and the
/// two containers involved (`ar` outside a package, `tar` inside), instead of
/// a Swift decoder per format and a hand-written `ar` walker.
public enum DebArchiveReader {
    /// Where a package's bytes are.
    public enum Source: Sendable {
        case path(String)
        case data(Data)
    }

    /// What one `data.tar` member is.
    public enum EntryKind: Sendable, Hashable {
        case file
        case directory
        case symbolicLink(target: String)
        /// A hard link to another member, by its absolute path.
        case hardLink(target: String)
        /// A FIFO, device or socket: listed, never something Apelin writes.
        case other(fileType: UInt32)
    }

    /// One member of `data.tar`, as the archive describes it.
    public struct Entry: Sendable, Hashable {
        /// Absolute, as dpkg lists it: `/var/jb/usr/bin/x`.
        public var path: String
        public var kind: EntryKind
        /// Permission bits (`0o7777`).
        public var mode: UInt16
        public var userID: Int64
        public var groupID: Int64
        public var userName: String?
        public var groupName: String?
        public var size: Int64
        public var modificationTime: Int64
        /// The bytes of a regular file no larger than the limit the caller
        /// passed; nil otherwise.
        public var contents: Data?
    }

    /// What a Debian package holds, read without writing anything.
    public struct Contents: Sendable {
        /// The `ar` members in order: `debian-binary`, `control.tar.zst`,
        /// `data.tar.zst`, and anything after them.
        public var members: [String]
        /// `control`, the maintainer scripts, `conffiles` and every other
        /// `control.tar` member up to `controlMemberLimit`, by name. A script
        /// may be a binary, so these are bytes.
        public var controlFiles: [String: Data]
        /// Every `data.tar` member, in archive order, the root left out.
        public var entries: [Entry]

        /// The `control` member parsed by `DebianControlFile`.
        public func control() throws -> DebianControlFile {
            guard let bytes = controlFiles["control"], let text = String(data: bytes, encoding: .utf8) else {
                throw PackageFormatError.notDebianPackage("control.tar has no control file")
            }
            return try DebianControlFile(parsing: text)
        }

        /// What the package installs that is not a directory, absolute.
        public var files: [String] {
            entries.filter { $0.kind != .directory }.map(\.path)
        }

        public var directories: [String] {
            entries.filter { $0.kind == .directory }.map(\.path)
        }
    }

    private static let chunkSize = 64 * 1024

    /// A control member larger than this is not read: nothing shows a script
    /// that long, and the size is the package's own word.
    public static let controlMemberLimit: Int64 = 1 << 20

    /// The bytes behind any compression filter libarchive knows, or the input
    /// unchanged when it carries none.
    public static func decompress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { bytes -> Data in
            let archive = try open(filters: true, formats: [archive_read_support_format_raw])
            defer { archive_read_free(archive) }
            try check(archive_read_open_memory(archive, bytes.baseAddress, bytes.count), archive)
            var entry: OpaquePointer?
            try check(archive_read_next_header(archive, &entry), archive)
            return try readData(archive)
        }
    }

    /// The `control` file of a Debian package, read without unpacking
    /// anything else.
    public static func control(of source: Source) throws -> String {
        try withControlArchive(source) { inner in
            var file: OpaquePointer?
            while archive_read_next_header(inner, &file) == ARCHIVE_OK {
                let name = pathname(file)
                guard name == "control" || name == "./control" else {
                    archive_read_data_skip(inner)
                    continue
                }
                guard archive_entry_size(file) <= controlMemberLimit else {
                    throw PackageFormatError.tooLarge("control is over \(controlMemberLimit) bytes")
                }
                return try String(decoding: readData(inner), as: UTF8.self)
            }
            throw PackageFormatError.notDebianPackage("control.tar has no control file")
        }
    }

    /// The names of the members of a Debian package's `control.tar`
    /// (`control`, `postinst`, ...), spelled as dpkg names them with no
    /// leading `./`. Nothing is read but the listing, and `data.tar` is
    /// never opened.
    public static func controlMembers(of source: Source) throws -> Set<String> {
        try withControlArchive(source) { inner in
            var names = Set<String>()
            var file: OpaquePointer?
            while true {
                let status = archive_read_next_header(inner, &file)
                if status == ARCHIVE_EOF {
                    return names
                }
                try check(status, inner)
                let name = try PackagePath.relative(pathname(file))
                if !name.isEmpty {
                    names.insert(name)
                }
                archive_read_data_skip(inner)
            }
        }
    }

    /// The whole listing of a Debian package. Both inner archives are
    /// streamed out of the outer `ar`, so a large `data.tar` is decoded and
    /// never held; only regular files no larger than `contentsLimit` bytes
    /// are kept, and none by default.
    ///
    /// Refused: a first member other than `debian-binary`, a format other
    /// than `2.0`, `control.tar` after `data.tar` or either one missing or
    /// twice, a path that escapes the root or appears twice, and more than
    /// `maximumEntryCount` entries.
    public static func contents(
        of source: Source,
        contentsLimit: Int64 = 0,
        maximumEntryCount: Int = 1_000_000,
    ) throws -> Contents {
        try withUTF8Names {
            try readContents(source, contentsLimit: contentsLimit, maximumEntryCount: maximumEntryCount)
        }
    }

    private static func readContents(
        _ source: Source,
        contentsLimit: Int64,
        maximumEntryCount: Int,
    ) throws -> Contents {
        try withOuter(source) { outer in
            var result = Contents(members: [], controlFiles: [:], entries: [])
            var seenPaths = Set<String>()
            var controlSeen = false, dataSeen = false
            var header: OpaquePointer?
            while true {
                let status = archive_read_next_header(outer, &header)
                if status == ARCHIVE_EOF {
                    break
                }
                try check(status, outer)
                let name = pathname(header)
                result.members.append(name)
                if result.members.count == 1 {
                    guard name == "debian-binary" else {
                        throw PackageFormatError.notDebianPackage("the first member is \(name.debugDescription)")
                    }
                    guard archive_entry_size(header) <= 64, try readData(outer) == Data("2.0\n".utf8) else {
                        throw PackageFormatError.notDebianPackage("debian-binary is not 2.0")
                    }
                    continue
                }
                let isControl = isControlMember(name)
                guard isControl || isDataMember(name) else {
                    archive_read_data_skip(outer)
                    continue
                }
                // control.tar comes first, once; data.tar after it, once
                let inOrder = isControl ? !controlSeen && !dataSeen : controlSeen && !dataSeen
                guard inOrder else {
                    throw PackageFormatError.notDebianPackage("control.tar and data.tar are out of order or repeated")
                }
                if isControl {
                    controlSeen = true
                } else {
                    dataSeen = true
                }
                try withInner(outer) { inner in
                    var entry: OpaquePointer?
                    while true {
                        let status = archive_read_next_header(inner, &entry)
                        if status == ARCHIVE_EOF {
                            break
                        }
                        try check(status, inner)
                        let relative = try PackagePath.relative(pathname(entry))
                        if relative.isEmpty {
                            continue
                        }
                        if isControl {
                            if archive_entry_size(entry) <= controlMemberLimit,
                               archive_entry_filetype(entry) == S_IFREG
                            {
                                result.controlFiles[relative] = try readData(inner)
                            }
                            continue
                        }
                        guard seenPaths.insert(relative).inserted else {
                            throw PackageFormatError.notDebianPackage("/\(relative) appears twice")
                        }
                        guard result.entries.count < maximumEntryCount else {
                            throw PackageFormatError.tooLarge("more than \(maximumEntryCount) entries")
                        }
                        try result.entries.append(describe(
                            entry!,
                            path: "/" + relative,
                            inner,
                            contentsLimit: contentsLimit,
                        ))
                    }
                }
            }
            guard controlSeen, dataSeen else {
                throw PackageFormatError.notDebianPackage("control.tar or data.tar is missing")
            }
            return result
        }
    }

    private static func isControlMember(_ name: String) -> Bool {
        name == "control.tar" || name.hasPrefix("control.tar.")
    }

    private static func isDataMember(_ name: String) -> Bool {
        name == "data.tar" || name.hasPrefix("data.tar.")
    }

    private static func describe(
        _ entry: OpaquePointer,
        path: String,
        _ inner: OpaquePointer,
        contentsLimit: Int64,
    ) throws -> Entry {
        let kind: EntryKind
        if let target = archive_entry_hardlink(entry) {
            kind = try .hardLink(target: "/" + PackagePath.relative(String(cString: target)))
        } else {
            switch archive_entry_filetype(entry) {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK:
                guard let target = archive_entry_symlink(entry) else {
                    throw PackageFormatError.notDebianPackage("\(path) is a link with no target")
                }
                kind = .symbolicLink(target: String(cString: target))
            case let other: kind = .other(fileType: UInt32(other))
            }
        }
        let size = archive_entry_size(entry)
        var contents: Data?
        if kind == .file, size <= contentsLimit {
            contents = try readData(inner)
        }
        return Entry(
            path: path,
            kind: kind,
            mode: UInt16(archive_entry_perm(entry) & 0o7777),
            userID: archive_entry_uid(entry),
            groupID: archive_entry_gid(entry),
            userName: archive_entry_uname(entry).map { String(cString: $0) },
            groupName: archive_entry_gname(entry).map { String(cString: $0) },
            size: size,
            modificationTime: Int64(archive_entry_mtime(entry)),
            contents: contents,
        )
    }

    // MARK: - Containers

    /// Runs `read` over the `control.tar.*` member: the outer `ar` is walked
    /// to it, and the member, which is small, is opened from memory.
    private static func withControlArchive<T>(_ source: Source, _ read: (OpaquePointer) throws -> T) throws -> T {
        try withUTF8Names {
            try withOuter(source) { outer in
                var entry: OpaquePointer?
                while true {
                    let status = archive_read_next_header(outer, &entry)
                    if status == ARCHIVE_EOF {
                        break
                    }
                    try check(status, outer)
                    guard isControlMember(pathname(entry)) else {
                        archive_read_data_skip(outer)
                        continue
                    }
                    guard archive_entry_size(entry) <= 64 * 1024 * 1024 else {
                        throw PackageFormatError.tooLarge("control.tar is over 64 MiB")
                    }
                    let member = try readData(outer)
                    return try member.withUnsafeBytes { bytes -> T in
                        let inner = try open(filters: true, formats: [archive_read_support_format_tar])
                        defer { archive_read_free(inner) }
                        try check(archive_read_open_memory(inner, bytes.baseAddress, bytes.count), inner)
                        return try read(inner)
                    }
                }
                throw PackageFormatError.notDebianPackage("no control.tar member")
            }
        }
    }

    /// The outer `ar`, opened over a path or a buffer.
    private static func withOuter<T>(_ source: Source, _ body: (OpaquePointer) throws -> T) throws -> T {
        let outer = try open(filters: false, formats: [archive_read_support_format_ar])
        defer { archive_read_free(outer) }
        switch source {
        case let .path(path):
            try check(archive_read_open_filename(outer, path, chunkSize), outer)
            return try body(outer)
        case let .data(data):
            return try data.withUnsafeBytes { bytes in
                try check(archive_read_open_memory(outer, bytes.baseAddress, bytes.count), outer)
                return try body(outer)
            }
        }
    }

    /// The `ar` member the outer archive stands at, read as a tar of its own
    /// through any filter, streamed: libarchive pulls the next chunk of the
    /// member each time it asks.
    private static func withInner(_ outer: OpaquePointer, _ body: (OpaquePointer) throws -> Void) throws {
        let inner = try open(filters: true, formats: [archive_read_support_format_tar])
        defer { archive_read_free(inner) }
        let member = Member(outer: outer)
        try check(
            archive_read_open(inner, Unmanaged.passUnretained(member).toOpaque(), nil, { _, client, buffer in
                guard let client else { return -1 }
                let member = Unmanaged<Member>.fromOpaque(client).takeUnretainedValue()
                buffer?.pointee = UnsafeRawPointer(member.buffer)
                return archive_read_data(member.outer, member.buffer, DebArchiveReader.chunkSize)
            }, nil),
            inner,
        )
        try withExtendedLifetime(member) { try body(inner) }
    }

    private final class Member {
        let outer: OpaquePointer
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: DebArchiveReader.chunkSize, alignment: 1)

        init(outer: OpaquePointer) {
            self.outer = outer
        }

        deinit {
            buffer.deallocate()
        }
    }

    // MARK: - libarchive

    /// libarchive converts entry names into the calling thread's codeset.
    /// An app starts in the C locale, where a UTF-8 name in a PAX header fails
    /// the header read and leaves the pathname NULL, so every reader that
    /// looks at names runs inside this: a UTF-8 LC_CTYPE on this thread only,
    /// the thread's previous locale restored after. Never `setlocale`, which
    /// is process-wide. Without a UTF-8 locale ASCII names still work.
    private static func withUTF8Names<T>(_ body: () throws -> T) rethrows -> T {
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

    private static func open(filters: Bool, formats: [(OpaquePointer?) -> Int32]) throws -> OpaquePointer {
        guard let archive = archive_read_new() else { throw PackageFormatError.archive("archive_read_new failed") }
        if filters {
            archive_read_support_filter_all(archive)
        }
        for format in formats {
            _ = format(archive)
        }
        return archive
    }

    private static func readData(_ archive: OpaquePointer) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
            if count < 0 {
                throw PackageFormatError.archive(message(archive))
            }
            if count == 0 {
                break
            }
            output.append(buffer, count: count)
        }
        return output
    }

    /// An entry's name as a Swift string; empty when it has none.
    private static func pathname(_ entry: OpaquePointer?) -> String {
        archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
    }

    private static func check(_ status: Int32, _ archive: OpaquePointer) throws {
        guard status == ARCHIVE_OK else { throw PackageFormatError.archive(message(archive)) }
    }

    private static func message(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "libarchive error"
    }
}
