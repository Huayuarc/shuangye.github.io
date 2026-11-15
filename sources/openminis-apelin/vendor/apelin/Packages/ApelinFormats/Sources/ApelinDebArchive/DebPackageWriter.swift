import ApelinDebian
import Foundation

/// Writes a Debian binary package: an `ar` container holding
/// `debian-binary`, `control.tar.<ext>` and `data.tar.<ext>`, in that order.
///
/// The output is deterministic. Entries are sorted by path with parents
/// first, every missing parent directory is added, every member is owned by
/// root:wheel, and every timestamp — in the tar headers, the `ar` headers and
/// nowhere else — is `modificationTime` unless an entry names its own. Two
/// writes of the same description give the same bytes, whatever machine and
/// whatever user ran them.
///
/// ```swift
/// let layout = PackageLayout.rootless
/// var control = DebianControlFile(
///     package: "com.example.tool", version: "1.0",
///     architecture: layout.architecture, description: "An example")
/// control["Maintainer"] = "Example <example@example.com>"
/// var writer = DebPackageWriter(control: control)
/// writer.entries.append(.file(try layout.commandLineTool(named: "tool"),
///                             copying: "build/tool", mode: 0o755))
/// writer.maintainerScripts[.postinst] = Data("#!/bin/sh\nexit 0\n".utf8)
/// try writer.write(toPath: "build/com.example.tool_1.0_iphoneos-arm64.deb")
/// ```
public struct DebPackageWriter: Sendable {
    public var control: DebianControlFile
    public var entries: [DebEntry] = []
    /// Written into `control.tar` with mode 0755.
    public var maintainerScripts: [MaintainerScript: Data] = [:]
    /// Other control members — `conffiles`, `triggers`, `shlibs` — written
    /// with mode 0644. Neither `control` nor a maintainer script's name.
    public var controlFiles: [String: Data] = [:]
    public var compression: DebCompression = .zstd
    /// The control member's own compression, when it should differ from the
    /// data's. Apelin's session host reads a package's control file itself
    /// before it hands the package to irisind, with system code only — gzip,
    /// xz or none — so a package for the install bridge sets `.gzip` here.
    /// nil uses `compression`.
    public var controlCompression: DebCompression?
    /// Seconds since 1970 for every member that does not name its own. A
    /// build passes its commit time, as `SOURCE_DATE_EPOCH` would.
    public var modificationTime: Int64 = 0

    public init(control: DebianControlFile) {
        self.control = control
    }

    /// The package as bytes.
    public func data() throws -> Data {
        let sink = MemorySink()
        try write(into: sink)
        return sink.data
    }

    /// Writes the package to `path`, atomically: into a temporary file beside
    /// it, flushed, then renamed over. A failure leaves nothing behind and
    /// whatever was at `path` untouched.
    public func write(toPath path: String) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw PackageFormatError.invalidPath(path.debugDescription) }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().path
        var template = Array((directory + "/." + url.lastPathComponent + ".XXXXXX").utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw PackageFormatError.system(errno: errno, "create \(directory)") }
        let temporary = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var renamed = false
        defer {
            close(descriptor)
            if !renamed {
                unlink(temporary)
            }
        }
        try write(into: DescriptorSink(descriptor: descriptor))
        guard fchmod(descriptor, 0o644) == 0 else { throw PackageFormatError.system(errno: errno, "chmod") }
        guard fsync(descriptor) == 0 else { throw PackageFormatError.system(errno: errno, "fsync") }
        guard rename(temporary, path) == 0 else { throw PackageFormatError.system(errno: errno, "rename to \(path)") }
        renamed = true
    }

    /// dpkg-gencontrol's estimate, in KiB: each regular file rounded up to a
    /// whole KiB, each directory and symbolic link one KiB. The root itself
    /// does not count.
    public func installedSize() throws -> Int64 {
        try Self.installedSize(of: normalizedEntries())
    }

    // MARK: - Writing

    private func write(into sink: PatchableSink) throws {
        let entries = try normalizedEntries()
        var control = control
        // computed from the entries, replacing any value the caller set
        control["Installed-Size"] = try String(Self.installedSize(of: entries))
        let controlText = try control.rendered()
        let controlMembers = try controlMembers(controlText)

        let ar = try ArWriter(sink: sink, modificationTime: modificationTime)
        try ar.addMember(name: "debian-binary", contents: Data("2.0\n".utf8))
        let controlCompression = controlCompression ?? compression
        try ar.addMember(name: "control.tar" + controlCompression.memberSuffix) { member in
            try writeTar(into: member, compression: controlCompression) { tar in
                try tar.writeHeader(name: "./", kind: .directory, mode: 0o755, modificationTime: modificationTime)
                for (name, mode, contents) in controlMembers {
                    try writeFile(contents, as: "./" + name, mode: mode, modificationTime: modificationTime, to: tar)
                }
            }
        }
        try ar.addMember(name: "data.tar" + compression.memberSuffix) { member in
            try writeTar(into: member, compression: compression) { tar in
                for entry in entries {
                    try write(entry, to: tar)
                }
            }
        }
    }

    /// `control` first, then the maintainer scripts, then the rest, each
    /// group by name.
    private func controlMembers(_ controlText: String) throws -> [(String, UInt16, Data)] {
        var members: [(String, UInt16, Data)] = [("control", 0o644, Data(controlText.utf8))]
        for script in maintainerScripts.keys.sorted() {
            members.append((script.rawValue, 0o755, maintainerScripts[script]!))
        }
        let reserved = Set(["control"] + MaintainerScript.allCases.map(\.rawValue))
        for name in controlFiles.keys.sorted() {
            guard PackagePath.isValidComponent(name), name.utf8.count <= 250, !reserved.contains(name) else {
                throw PackageFormatError.invalidEntry("control member \(name.debugDescription)")
            }
            members.append((name, 0o644, controlFiles[name]!))
        }
        return members
    }

    private func writeTar(
        into member: ByteSink,
        compression: DebCompression,
        _ body: (TarWriter) throws -> Void,
    ) throws {
        let compressor = try compression == .none ? nil : CompressingSink(compression: compression, into: member)
        let tar = TarWriter(sink: compressor ?? member)
        try body(tar)
        try tar.finish()
        try compressor?.finish()
    }

    private func write(_ entry: NormalizedEntry, to tar: TarWriter) throws {
        let time = entry.entry.modificationTime ?? modificationTime
        let mode = entry.entry.mode
        switch entry.entry.kind {
        case .directory:
            try tar.writeHeader(name: entry.tarName, kind: .directory, mode: mode, modificationTime: time)
        case let .symbolicLink(target):
            try tar.writeHeader(
                name: entry.tarName,
                kind: .symbolicLink(target: target),
                mode: 0o777,
                modificationTime: time,
            )
        case let .file(.data(contents)):
            try writeFile(contents, as: entry.tarName, mode: mode, modificationTime: time, to: tar)
        case let .file(.file(source)):
            try streamFile(source, as: entry.tarName, mode: mode, modificationTime: time, to: tar)
        }
    }

    private func writeFile(
        _ contents: Data,
        as name: String,
        mode: UInt16,
        modificationTime: Int64,
        to tar: TarWriter,
    ) throws {
        try tar.writeHeader(
            name: name,
            kind: .file(size: Int64(contents.count)),
            mode: mode,
            modificationTime: modificationTime,
        )
        try contents.withUnsafeBytes { try tar.writeContents($0) }
        try tar.finishContents(size: Int64(contents.count))
    }

    private func streamFile(
        _ source: String,
        as name: String,
        mode: UInt16,
        modificationTime: Int64,
        to tar: TarWriter,
    ) throws {
        let descriptor = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PackageFormatError.system(errno: errno, "open \(source)") }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw PackageFormatError.system(errno: errno, "stat \(source)") }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw PackageFormatError.invalidEntry("\(source) is not a regular file")
        }
        let size = Int64(status.st_size)
        try tar.writeHeader(name: name, kind: .file(size: size), mode: mode, modificationTime: modificationTime)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        var remaining = size
        while remaining > 0 {
            let got = read(descriptor, buffer.baseAddress, min(buffer.count, Int(remaining)))
            if got < 0 {
                if errno == EINTR {
                    continue
                }
                throw PackageFormatError.system(errno: errno, "read \(source)")
            }
            guard got > 0 else { throw PackageFormatError.invalidEntry("\(source) shrank while it was being packaged") }
            try tar.writeContents(UnsafeRawBufferPointer(rebasing: buffer[0 ..< got]))
            remaining -= Int64(got)
        }
        // One byte more means the header already written is wrong.
        guard read(descriptor, buffer.baseAddress, 1) == 0 else {
            throw PackageFormatError.invalidEntry("\(source) grew while it was being packaged")
        }
        try tar.finishContents(size: size)
    }

    // MARK: - Normalizing

    private struct NormalizedEntry {
        var components: [String]
        var entry: DebEntry

        /// `./`, `./usr/`, `./usr/bin/x`: dpkg-deb's spelling, directories
        /// with a trailing slash.
        var tarName: String {
            let joined = components.joined(separator: "/")
            if case .directory = entry.kind {
                return joined.isEmpty ? "./" : "./" + joined + "/"
            }
            return "./" + joined
        }
    }

    /// Validated, deduplicated, with every parent present, sorted so a
    /// directory comes before what it holds.
    private func normalizedEntries() throws -> [NormalizedEntry] {
        var byPath: [[String]: NormalizedEntry] = [:]
        for entry in entries {
            let components = try PackagePath.components(ofAbsolute: entry.path)
            guard entry.mode & ~0o7777 == 0 else {
                throw PackageFormatError.invalidEntry("\(entry.path) has mode bits outside 0o7777")
            }
            switch entry.kind {
            case let .symbolicLink(target):
                guard !target.isEmpty, !target.utf8.contains(0), !target.utf8.contains(0x0A) else {
                    throw PackageFormatError.invalidEntry("\(entry.path) has an invalid link target")
                }
                guard !components.isEmpty else { throw PackageFormatError.invalidEntry("the root cannot be a link") }
            case .file:
                guard !components.isEmpty else { throw PackageFormatError.invalidEntry("the root cannot be a file") }
            case .directory:
                break
            }
            guard byPath[components] == nil else {
                throw PackageFormatError.invalidEntry("\(entry.path) is listed twice")
            }
            byPath[components] = NormalizedEntry(components: components, entry: entry)
        }
        for components in Array(byPath.keys) {
            for depth in 0 ..< components.count {
                let parent = Array(components[0 ..< depth])
                if let existing = byPath[parent] {
                    guard case .directory = existing.entry.kind else {
                        throw PackageFormatError.invalidEntry("\(existing.entry.path) holds entries but is not a directory")
                    }
                    continue
                }
                let path = "/" + parent.joined(separator: "/")
                byPath[parent] = NormalizedEntry(components: parent, entry: .directory(path))
            }
        }
        if byPath[[]] == nil {
            byPath[[]] = NormalizedEntry(components: [], entry: .directory("/"))
        }
        return byPath.values.sorted { Self.precedes($0.components, $1.components) }
    }

    /// Component-wise byte order: a parent sorts before its children, and
    /// `a/b` before `a.b` — what a plain string sort gets wrong.
    private static func precedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        return lhs.count < rhs.count
    }

    private static func installedSize(of entries: [NormalizedEntry]) throws -> Int64 {
        var kibibytes: Int64 = 0
        for entry in entries where !entry.components.isEmpty {
            switch entry.entry.kind {
            case .directory, .symbolicLink:
                kibibytes += 1
            case let .file(.data(contents)):
                kibibytes += (Int64(contents.count) + 1023) / 1024
            case let .file(.file(source)):
                var status = stat()
                guard lstat(source, &status) == 0 else {
                    throw PackageFormatError.system(errno: errno, "lstat \(source)")
                }
                kibibytes += (Int64(status.st_size) + 1023) / 1024
            }
        }
        return kibibytes
    }
}
