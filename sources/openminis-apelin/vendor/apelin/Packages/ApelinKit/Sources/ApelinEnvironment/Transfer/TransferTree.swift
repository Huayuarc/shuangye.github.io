import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// A folder as a transfer file's members: walked with `lstat`, never
/// following a link, each folder before what it holds, names sorted, every
/// file hashed. A link must be relative and stay inside the folder when
/// followed through the folder's own links.
struct TransferTree {
    let root: URL
    var members: [TransferMember] = []
    /// Where each file member's bytes are, by member path.
    var sources: [String: URL] = [:]
    /// What was left out and why, for a lenient walk.
    var leftOut: [String] = []

    /// How a walk treats what it finds.
    struct Rules {
        /// Whether to leave a path out (relative, and whether it is a folder).
        var skip: (String, Bool) throws -> Bool = { _, _ in false }
        /// Leave out what cannot travel — a link leading out, a device, a
        /// socket — with a note, rather than refusing the whole export.
        var lenient = false
    }

    static func collect(_ root: URL, rules: Rules = Rules(), reporter: TaskReporter) throws -> TransferTree {
        guard let base = CanonicalPath.resolve(root.path) else {
            throw ApelinError(.notFound, "\(root.lastPathComponent) is not there")
        }
        var tree = TransferTree(root: URL(fileURLWithPath: base, isDirectory: true))
        var scanned: Int64 = 0
        let throttle = ProgressThrottle()
        reporter.progress("collecting", completed: 0)
        try tree.walk(
            URL(fileURLWithPath: base, isDirectory: true),
            relative: [],
            rules: rules,
            scanned: &scanned,
            throttle: throttle,
            reporter: reporter,
        )

        var links: [[String]: String] = [:]
        for member in tree.members where member.kind == .link {
            links[member.path.split(separator: "/").map(String.init)] = member.target
        }
        let outside = links.keys
            .filter { !ToolchainPackager.staysInside($0, links: links) }
            .map { $0.joined(separator: "/") }
        if !outside.isEmpty {
            guard rules.lenient else {
                throw ApelinError(.conflict, "\(outside.sorted()[0]) links outside \(root.lastPathComponent)")
            }
            let dropped = Set(outside)
            tree.members.removeAll { dropped.contains($0.path) }
            tree.leftOut += outside.sorted().map { "\($0) (a link leading outside)" }
        }
        reporter.progress("collecting", completed: scanned)
        try tree.hashFiles(reporter: reporter)
        return tree
    }

    private mutating func walk(
        _ folder: URL,
        relative: [String],
        rules: Rules,
        scanned: inout Int64,
        throttle: ProgressThrottle,
        reporter: TaskReporter,
    ) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        } catch {
            throw ApelinError(.unavailable, "cannot read \(relative.joined(separator: "/")): \(error)")
        }
        for name in names {
            try reporter.checkCancelled()
            let components = relative + [name]
            let path = components.joined(separator: "/")
            let url = folder.appendingPathComponent(name)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { throw ArchiveExtractor.posix("read \(path)") }
            let type = metadata.st_mode & S_IFMT
            scanned += 1
            if throttle.shouldEmit() {
                reporter.progress("collecting", completed: scanned, detail: path)
            }
            if try rules.skip(path, type == S_IFDIR) {
                continue
            }
            switch type {
            case S_IFDIR:
                members.append(TransferMember(path: path, kind: .directory))
                try walk(
                    url,
                    relative: components,
                    rules: rules,
                    scanned: &scanned,
                    throttle: throttle,
                    reporter: reporter,
                )
            case S_IFREG:
                members.append(TransferMember(
                    path: path,
                    kind: .file,
                    size: Int64(metadata.st_size),
                    executable: metadata.st_mode & 0o111 != 0 ? true : nil,
                ))
                sources[path] = url
            case S_IFLNK:
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                guard !target.isEmpty, !target.hasPrefix("/"), !CanonicalPath.containsNUL(target) else {
                    guard rules.lenient else { throw ApelinError(.conflict, "\(path) is an absolute link") }
                    leftOut.append("\(path) (an absolute link)")
                    continue
                }
                members.append(TransferMember(path: path, kind: .link, target: target))
            default:
                guard rules.lenient else { throw ApelinError(.conflict, "\(path) is a device, FIFO or socket") }
                leftOut.append("\(path) (not a file, folder or link)")
            }
        }
    }

    private mutating func hashFiles(reporter: TaskReporter) throws {
        reporter.stage("hashing")
        let total = members.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var completed: Int64 = 0
        let throttle = ProgressThrottle()
        reporter.progress("hashing", completed: 0, total: total)
        for index in members.indices where members[index].kind == .file {
            try reporter.checkCancelled()
            let member = members[index]
            guard let source = sources[member.path] else {
                throw ApelinError(.internal, "no source for \(member.path)")
            }
            let (digest, size) = try TransferDigest.file(source, inside: root) { count in
                try reporter.checkCancelled()
                if throttle.shouldEmit() {
                    reporter.progress("hashing", completed: completed + count, total: total, detail: member.path)
                }
            }
            guard size == member.size else {
                throw ApelinError(.conflict, "\(member.path) changed while it was being exported; export it again")
            }
            members[index].sha256 = digest
            completed += size
        }
        reporter.progress("hashing", completed: completed, total: total)
    }
}
