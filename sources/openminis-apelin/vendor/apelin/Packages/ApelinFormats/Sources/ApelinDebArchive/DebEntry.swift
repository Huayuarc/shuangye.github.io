import ApelinDebian
import Foundation

/// One thing a package installs: a directory, a regular file or a symbolic
/// link, at a package path (`/var/jb/usr/bin/x`, `/Applications/X.app`).
///
/// Every entry is owned by root:wheel (uid 0, gid 0) in the archive, as
/// `dpkg-deb --root-owner-group` writes it: whoever built the package, the
/// device installs it as root's.
public struct DebEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file(FileContent)
        case symbolicLink(target: String)
    }

    /// Where a regular file's bytes come from.
    public enum FileContent: Sendable, Hashable {
        /// Bytes already in memory.
        case data(Data)
        /// A regular file on disk, streamed when the archive is written. It is
        /// opened without following a symlink, must still be a regular file,
        /// and must not change size between being listed and being read.
        case file(path: String)
    }

    /// An absolute, canonical package path. Parents need not be listed: the
    /// writer adds any directory that is missing with mode 0755.
    public var path: String
    public var kind: Kind
    /// Permission bits only (`0o7777`): setuid, setgid and sticky included,
    /// the file type never.
    public var mode: UInt16
    /// Seconds since 1970; nil takes the writer's `modificationTime`, which is
    /// what makes two builds of the same tree byte-identical.
    public var modificationTime: Int64?

    public init(path: String, kind: Kind, mode: UInt16, modificationTime: Int64? = nil) {
        self.path = path
        self.kind = kind
        self.mode = mode
        self.modificationTime = modificationTime
    }

    public static func directory(_ path: String, mode: UInt16 = 0o755) -> DebEntry {
        DebEntry(path: path, kind: .directory, mode: mode)
    }

    public static func file(_ path: String, contents: Data, mode: UInt16 = 0o644) -> DebEntry {
        DebEntry(path: path, kind: .file(.data(contents)), mode: mode)
    }

    public static func file(_ path: String, copying sourcePath: String, mode: UInt16 = 0o644) -> DebEntry {
        DebEntry(path: path, kind: .file(.file(path: sourcePath)), mode: mode)
    }

    public static func symbolicLink(_ path: String, target: String) -> DebEntry {
        DebEntry(path: path, kind: .symbolicLink(target: target), mode: 0o755)
    }

    /// A directory tree on disk as entries under `packagePath`: the directory
    /// itself, then everything in it, symlinks kept as links and never
    /// followed, modes taken from disk. Ownership is not: every entry is
    /// root's in the archive.
    ///
    /// A FIFO, socket or device node is refused — nothing a build produces
    /// should contain one, and dpkg would install it as root.
    public static func tree(fromDirectory sourceDirectory: String, at packagePath: String) throws -> [DebEntry] {
        _ = try PackagePath.components(ofAbsolute: packagePath)
        var entries: [DebEntry] = []
        try walk(sourceDirectory, packagePath: packagePath, into: &entries)
        return entries
    }

    private static func walk(_ source: String, packagePath: String, into entries: inout [DebEntry]) throws {
        var status = stat()
        guard lstat(source, &status) == 0 else {
            throw PackageFormatError.system(errno: errno, "lstat \(source)")
        }
        let mode = UInt16(status.st_mode & 0o7777)
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            entries.append(DebEntry(path: packagePath, kind: .directory, mode: mode))
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: source).sorted()
            } catch {
                throw PackageFormatError.system(errno: EIO, "list \(source)")
            }
            for name in names {
                guard PackagePath.isValidComponent(name) else {
                    throw PackageFormatError.invalidPath("\(source)/\(name)".debugDescription)
                }
                let child = packagePath == "/" ? "/" + name : packagePath + "/" + name
                try walk(source + "/" + name, packagePath: child, into: &entries)
            }
        case S_IFREG:
            entries.append(DebEntry(path: packagePath, kind: .file(.file(path: source)), mode: mode))
        case S_IFLNK:
            let target: String
            do {
                target = try FileManager.default.destinationOfSymbolicLink(atPath: source)
            } catch {
                throw PackageFormatError.system(errno: EIO, "readlink \(source)")
            }
            entries.append(DebEntry(path: packagePath, kind: .symbolicLink(target: target), mode: mode))
        default:
            throw PackageFormatError.invalidEntry("\(source) is not a file, directory or symbolic link")
        }
    }
}

/// The maintainer scripts dpkg runs, by their member names.
public enum MaintainerScript: String, Sendable, Hashable, CaseIterable, Comparable {
    case preinst
    case postinst
    case prerm
    case postrm
    /// The legacy install hook; Irisin's installer still runs it.
    case extrainst = "extrainst_"

    public static func < (lhs: MaintainerScript, rhs: MaintainerScript) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
