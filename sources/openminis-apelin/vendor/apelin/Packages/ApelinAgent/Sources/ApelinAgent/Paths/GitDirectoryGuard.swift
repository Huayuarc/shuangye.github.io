import enum ApelinCore.CanonicalPath
import Foundation

/// The file tools never write a repository's git directory. A config, hook
/// or `gitdir:` pointer written there would be read by every git the
/// session host runs as mobile — after its preset check has looked, too —
/// so the repository changes only through the host's git operations.
///
/// A git directory is any entry named `.git` (compared without case, as the
/// file system may) and everything below it, plus what a `.git` that is a
/// file or a link names — its `gitdir:` target, or the link's target even
/// before it exists — and that directory's `commondir`, and the `commondir`
/// of a `.git` directory; and a folder git takes as one by what is in it,
/// a bare repository's layout, which is never completed
/// (`refuseBareLayout`). Reading any of it is allowed.
///
/// Two checks decide it. The target's own path, looked at fresh every time:
/// no component is a `.git`, and no `.git` in a folder on the way down from
/// the root names a directory the target is in — a few lstats. And every
/// other `.git` file or link in the project, since one anywhere may name any
/// folder (`sub/.git` holding `gitdir: ../store/repo.git` makes
/// `store/repo.git/config` a repository's config): only a walk finds those.
/// The walk has no cap, so a large project stays writable, and refuses the
/// write only when it cannot read a folder, where such a file would go
/// unseen. It runs once per write: `resolveForWrite` walks and its
/// `WriteTarget` hands the answer to `commit`, which repeats only the path
/// check; the approval gate resolves without it, since a git directory does
/// not change the gate's answer and the tool refuses it anyway.
extension ScopedRoot {
    /// Throws `gitDirectory` when `canonical` — an existing ancestor's
    /// realpath followed by plain components — is in a git directory by its
    /// own path: a `.git` component, or what a `.git` in an ancestor names.
    func refuseGitPath(_ canonical: String, requested: String) throws {
        let parts = Self.split(canonical)
        if parts.dropFirst(components.count).contains(where: Self.isGitName) {
            throw PathPolicyError.gitDirectory(requested)
        }
        // Each folder from the root down to the target's own.
        for count in components.count ..< parts.count {
            let entry = "/" + (parts.prefix(count) + [".git"]).joined(separator: "/")
            var info = stat()
            guard lstat(entry, &info) == 0 else { continue }
            for directory in GitPointers.named(by: entry, info: info)
                where CanonicalPath.isCanonical(canonical, inside: directory)
            {
                throw PathPolicyError.gitDirectory(requested)
            }
        }
        try refuseBareLayout(canonical, requested: requested)
    }

    /// Throws `gitDirectory` when writing `canonical` would make, or write
    /// in, a folder git takes as a git directory by its contents alone, as
    /// a bare repository: git's `is_git_directory` wants a `HEAD` and either
    /// `objects/` and `refs/` or a `commondir`. So no file is written below
    /// a folder that has that layout; nothing below the `objects/` or
    /// `refs/` of a folder with a `HEAD`; and no `HEAD` beside `objects/`
    /// and `refs/` or a `commondir`, nor a `commondir` beside a `HEAD`. In
    /// whatever order the files come, the one that would complete the
    /// layout is refused. A `config` or `HEAD` in any other folder is an
    /// ordinary project file. Names written are compared without case, as
    /// the file system may; what exists is asked of the file system.
    func refuseBareLayout(_ canonical: String, requested: String) throws {
        let parts = Self.split(canonical)
        guard parts.count > components.count else { return }
        for count in components.count ..< parts.count {
            let folder = "/" + parts.prefix(count).joined(separator: "/")
            let has = { (name: String) -> Bool in
                var info = stat()
                return lstat(folder + "/" + name, &info) == 0
            }
            let head = has("HEAD")
            let stores = has("objects") && has("refs")
            let common = has("commondir")
            let next = parts[count].lowercased()
            let refused: Bool = if count < parts.count - 1 {
                // A folder on the way down to the target.
                (head && (stores || common)) || (head && (next == "objects" || next == "refs"))
            } else {
                // The target's own folder, and the name written into it.
                switch next {
                case "head": stores || common
                case "commondir": head
                default: head && (stores || common)
                }
            }
            if refused {
                throw PathPolicyError.gitDirectory(requested)
            }
        }
    }

    /// Walks the project for its `.git` files and links and throws
    /// `gitDirectory` when `canonical` is in a directory one names; answers
    /// the walk, for `commit` to check against again.
    func gitPointers(refusing canonical: String, requested: String) throws -> GitPointers {
        let pointers = try GitPointers.find(in: self)
        try pointers.refuse(canonical, requested: requested)
        return pointers
    }

    static func isGitName(_ component: String) -> Bool {
        component.lowercased() == ".git"
    }

    /// The most links `canonicalLeniently` follows, as the kernel's MAXSYMLINKS.
    private static let maxLinkHops = 32

    /// `target` made canonical one component at a time — each existing step
    /// through realpath, so a link resolves as the kernel would, and a link
    /// whose target is missing through readlink, so the answer is the path
    /// it will name once made — and the missing remainder appended plainly.
    static func canonicalLeniently(_ target: String, from base: String) -> String? {
        guard !CanonicalPath.containsNUL(target) else { return nil }
        let absolute = target.hasPrefix("/") ? target : base + "/" + target
        var pending = ArraySlice(split(absolute))
        var current = "/"
        var hops = 0
        var missing = false
        while let part = pending.popFirst() {
            if part == "." {
                continue
            }
            if part == ".." {
                current = (current as NSString).deletingLastPathComponent
                continue
            }
            let next = current == "/" ? "/" + part : current + "/" + part
            if !missing, let real = CanonicalPath.resolve(next) {
                current = real
                continue
            }
            var info = stat()
            if !missing, lstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                // A dangling link: its text stands in for this component.
                hops += 1
                guard hops <= maxLinkHops, let text = readLink(next) else { return nil }
                if text.hasPrefix("/") {
                    current = "/"
                }
                pending = ArraySlice(split(text)) + pending
                continue
            }
            missing = true
            current = next
        }
        return current
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The canonical directories that a project's `.git` files and links name,
/// with their `commondir`s and those of its `.git` directories, as one walk
/// found them.
struct GitPointers: Sendable {
    let directories: [String]

    func refuse(_ canonical: String, requested: String) throws {
        for directory in directories where CanonicalPath.isCanonical(canonical, inside: directory) {
            throw PathPolicyError.gitDirectory(requested)
        }
    }

    /// Walks the whole project by path bytes, never through a link and never
    /// into a `.git` directory, which the name rule covers already.
    static func find(in root: ScopedRoot) throws -> GitPointers {
        root.onGitWalk?()
        var found: [String] = []
        var folders: [[UInt8]] = [Array(root.path.utf8)]
        while let folder = folders.popLast() {
            let descriptor = withCPath(folder) { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else {
                // Gone, or replaced by a file or link, since it was listed.
                if errno == ENOENT || errno == ENOTDIR || errno == ELOOP {
                    continue
                }
                throw unreadable(folder, root: root)
            }
            guard let handle = fdopendir(descriptor) else {
                close(descriptor)
                throw unreadable(folder, root: root)
            }
            defer { closedir(handle) }
            while true {
                errno = 0
                guard let entry = readdir(handle) else {
                    if errno != 0 {
                        throw unreadable(folder, root: root)
                    }
                    break
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(Int(entry.pointee.d_namlen))) }
                if name == Array(".".utf8) || name == Array("..".utf8) {
                    continue
                }
                let path = folder + [UInt8(ascii: "/")] + name
                if ScopedRoot.isGitName(String(decoding: name, as: UTF8.self)) {
                    // A pointer in a folder whose name is not UTF-8 could
                    // not be canonicalised as the paths it is compared with.
                    guard let text = String(bytes: path, encoding: .utf8) else {
                        throw unreadable(folder, root: root)
                    }
                    var info = stat()
                    guard lstat(text, &info) == 0 else { continue }
                    found += named(by: text, info: info)
                    continue
                }
                var type = Int32(entry.pointee.d_type)
                if type == DT_UNKNOWN {
                    var info = stat()
                    guard withCPath(path, { lstat($0, &info) }) == 0 else { continue }
                    type = (info.st_mode & S_IFMT) == S_IFDIR ? DT_DIR : DT_REG
                }
                if type == DT_DIR {
                    folders.append(path)
                }
            }
        }
        return GitPointers(directories: found)
    }

    /// What the `.git` entry at `entry` names: a directory's `commondir`; a
    /// link's target, read as a pointer file when it is one; a file's
    /// `gitdir:`; each with that directory's `commondir`.
    static func named(by entry: String, info: stat) -> [String] {
        let folder = (entry as NSString).deletingLastPathComponent
        var found: [String] = []
        var file = entry
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            // A worktree's shares its config and hooks with the one it names.
            if let real = CanonicalPath.resolve(entry), let common = commonDirectory(of: real) {
                found.append(common)
            }
            return found
        case S_IFLNK:
            // A target that does not exist yet is followed too, or it could
            // be made afterwards.
            guard let real = ScopedRoot.canonicalLeniently(entry, from: "/") else { return found }
            found.append(real)
            var target = stat()
            guard stat(real, &target) == 0, (target.st_mode & S_IFMT) == S_IFREG else {
                if let common = commonDirectory(of: real) {
                    found.append(common)
                }
                return found
            }
            file = real
        case S_IFREG:
            break
        default:
            return found
        }
        guard let directory = gitFileTarget(file, from: folder) else { return found }
        found.append(directory)
        if let common = commonDirectory(of: directory) {
            found.append(common)
        }
        return found
    }

    /// The canonical `gitdir:` of a `.git` file, read as git does: relative
    /// to the folder holding the `.git` name.
    private static func gitFileTarget(_ file: String, from folder: String) -> String? {
        guard let value = firstLine(of: file), value.hasPrefix("gitdir:") else { return nil }
        let target = value.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return ScopedRoot.canonicalLeniently(target, from: folder)
    }

    /// The canonical `commondir` a git directory shares objects and config
    /// with (a worktree's), when it names one.
    private static func commonDirectory(of directory: String) -> String? {
        guard let value = firstLine(of: directory + "/commondir"), !value.isEmpty else { return nil }
        return ScopedRoot.canonicalLeniently(value, from: directory)
    }

    private static func firstLine(of file: String) -> String? {
        let descriptor = open(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func withCPath<Result>(
        _ path: [UInt8],
        _ body: (UnsafePointer<CChar>) -> Result,
    ) -> Result {
        (path + [0]).withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { body($0.baseAddress!) }
        }
    }

    private static func unreadable(_ folder: [UInt8], root: ScopedRoot) -> PathPolicyError {
        let reason = String(cString: strerror(errno))
        let name = root.relative(String(decoding: folder, as: UTF8.self))
        return .io("could not look for git directories in \(name): \(reason)")
    }
}
