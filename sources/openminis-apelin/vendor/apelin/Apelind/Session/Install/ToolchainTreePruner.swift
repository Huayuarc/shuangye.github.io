import ApelinCore
import Darwin
import Foundation

/// What a removed toolchain package leaves behind on roothide. dpkg takes
/// away every file and link the package lists, but roothide puts a
/// `.jbroot` link in each of its folders, which no package lists, so none
/// of them is ever empty and dpkg leaves them all (`ToolchainService.exists`
/// reads such a tree as gone). The session host takes that skeleton away as
/// root: after the bridge removed a toolchain package, and at start for a
/// toolchain whose package is not on the device.
///
/// Only `<install root>/usr/lib/apelin/toolchains/<id>`, and only when every
/// entry below it is a folder or a link named `.jbroot`: a file, any other
/// link, anything that cannot be read and anything past the caps keeps the
/// whole tree as it is. Nothing is followed, a `.jbroot` link is unlinked
/// without being read, and the folders go bottom up, the toolchain's own
/// last.
enum ToolchainTreePruner {
    static let maximumNamesPerFolder = 2000
    static let maximumEntries = 20000
    static let maximumDepth = 64
    /// The link roothide adds to every folder a package makes.
    static let rootLink = ".jbroot"

    enum Outcome: Equatable {
        /// Only folders and `.jbroot` links were there, and now nothing is.
        case pruned
        /// There is no such folder.
        case absent
        /// Left as it was, and why.
        case kept(String)
    }

    /// Where irisind lays toolchain packages down (`ToolchainManifest.installRelativePath`).
    static func folder(installRoot: String) -> String {
        (installRoot == "/" ? "" : installRoot) + "/usr/lib/apelin/toolchains"
    }

    /// `wiki.qaq.apelin.toolchain.<id>` → `<id>`; nil for any other package.
    static func toolchainID(packageID: String) -> String? {
        guard packageID.hasPrefix(ManagedPackagePolicy.toolchainPrefix) else { return nil }
        let id = String(packageID.dropFirst(ManagedPackagePolicy.toolchainPrefix.count))
        return isFolderName(id) ? id : nil
    }

    /// An ID the bridge takes a toolchain artifact by (`InstallBridge.toolchainID`),
    /// spelled as it is: one folder name, with no NUL, `/` or leading `.`.
    static func isFolderName(_ id: String) -> Bool {
        InstallBridge.toolchainID("toolchain-" + id) == id
    }

    /// The toolchain folders there are, by ID.
    static func toolchainIDs(installRoot: String) -> [String] {
        guard let parent = openFolder(installRoot: installRoot) else { return [] }
        defer { close(parent) }
        return (names(in: parent) ?? []).filter(isFolderName).sorted()
    }

    /// Takes `<toolchains>/<id>` away when it is nothing but a skeleton.
    static func prune(installRoot: String, id: String) -> Outcome {
        guard isFolderName(id) else { return .kept("\(id.debugDescription) is not a toolchain's folder name") }
        guard let parent = openFolder(installRoot: installRoot) else {
            var metadata = stat()
            let missing = lstat(folder(installRoot: installRoot), &metadata) != 0 && errno == ENOENT
            return missing ? .absent : .kept("usr/lib/apelin/toolchains is not a folder inside the install root")
        }
        defer { close(parent) }
        var metadata = stat()
        guard fstatat(parent, id, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .absent : .kept("\(id) could not be read")
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return .kept("\(id) is not a folder") }
        // Looked through whole before anything goes, so a file deep down
        // keeps every folder and link above and beside it.
        var entries = 0
        if let reason = walk(parent, id, path: id, depth: 0, entries: &entries, removing: false) {
            return .kept(reason)
        }
        entries = 0
        if let reason = walk(parent, id, path: id, depth: 0, entries: &entries, removing: true) {
            return .kept("it changed while it was being removed: " + reason)
        }
        return .pruned
    }

    /// The folder `name` in `parent`: nil when it holds nothing but folders
    /// and `.jbroot` links, at any depth, else why not. With `removing`,
    /// each of them goes as it is reached, and the folder after them.
    private static func walk(
        _ parent: Int32,
        _ name: String,
        path: String,
        depth: Int,
        entries: inout Int,
        removing: Bool,
    ) -> String? {
        guard depth < maximumDepth else { return "\(path) is more than \(maximumDepth) folders deep" }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return "\(path) could not be opened" }
        let reason = contents(of: descriptor, path: path, depth: depth, entries: &entries, removing: removing)
        close(descriptor)
        if let reason {
            return reason
        }
        guard !removing || unlinkat(parent, name, AT_REMOVEDIR) == 0 else { return "\(path) could not be removed" }
        return nil
    }

    private static func contents(
        of descriptor: Int32,
        path: String,
        depth: Int,
        entries: inout Int,
        removing: Bool,
    ) -> String? {
        guard let names = names(in: descriptor) else {
            return "\(path) could not be read or holds more than \(maximumNamesPerFolder) names"
        }
        for name in names {
            entries += 1
            guard entries <= maximumEntries else { return "it holds more than \(maximumEntries) entries" }
            let child = path + "/" + name
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { return "\(child) could not be read" }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                if let reason = walk(
                    descriptor,
                    name,
                    path: child,
                    depth: depth + 1,
                    entries: &entries,
                    removing: removing,
                ) {
                    return reason
                }
            case S_IFLNK where name == rootLink:
                guard !removing || unlinkat(descriptor, name, 0) == 0 else { return "\(child) could not be removed" }
            case S_IFLNK:
                return "\(child) is a link"
            case S_IFREG:
                return "\(child) is a file"
            default:
                return "\(child) is a special file"
            }
        }
        return nil
    }

    /// The folder's names but `.` and `..`; nil when it cannot be read whole
    /// or holds more than the cap.
    private static func names(in descriptor: Int32) -> [String]? {
        let copy = dup(descriptor)
        guard copy >= 0 else { return nil }
        guard let directory = fdopendir(copy) else {
            close(copy)
            return nil
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { break }
            // A name that is not UTF-8 does not come back the same, so it
            // cannot be looked at again and keeps the tree.
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." {
                continue
            }
            guard names.count < maximumNamesPerFolder else { return nil }
            names.append(name)
        }
        return errno == 0 ? names : nil
    }

    /// The toolchains folder, by its canonical path once that is found
    /// inside the canonical install root.
    private static func openFolder(installRoot: String) -> Int32? {
        guard let root = CanonicalPath.resolve(installRoot),
              let folder = CanonicalPath.resolve(folder(installRoot: installRoot)),
              CanonicalPath.isCanonical(folder, inside: root)
        else { return nil }
        let descriptor = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return descriptor >= 0 ? descriptor : nil
    }
}
