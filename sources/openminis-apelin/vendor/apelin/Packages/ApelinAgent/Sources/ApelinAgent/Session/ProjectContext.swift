import ApelinCore
import Darwin
import Foundation

/// What the model reads once, with the first message of a project's
/// conversation: the project's description and a bounded file tree, so it
/// does not spend its first turns listing files.
///
/// It is added to the text the model sees, never to the message the app
/// shows, and only when the conversation is empty: from then on it is in
/// the transcript, which is cached with the rest of the conversation and
/// read back when the session is reopened, so it is neither repeated nor
/// lost. The system prompt stays free of it, so a file the agent adds does
/// not change every later prompt. General Chat has no project and gets none.
enum ProjectContext {
    static let openingTag = "<project-context>"
    static let closingTag = "</project-context>"
    private static let maximumManifestBytes = 1 << 20
    /// What one manifest field may add, and how many items of a list.
    private static let maximumFieldLength = 200
    private static let maximumListed = 20

    /// The block, ending with a blank line, to put before the user's text.
    /// `repository` is the host's `gitStatus` of the project, when it
    /// answered in time.
    static func make(project: ProjectIdentity, root: ScopedRoot, repository: GitStatusToolResponse? = nil) -> String {
        var lines = [
            openingTag,
            "Apelin added this to the first message: the project when the conversation began. It is context, not the user's request, and files change after it.",
        ]
        let manifest = manifest(in: root)
        let displayName = text(manifest?["displayName"]).flatMap { $0.isEmpty ? nil : $0 }
        if let displayName, displayName != project.name.rawValue {
            lines.append("Project “\(displayName)” (folder \(project.name.rawValue), id \(project.id))")
        } else {
            lines.append("Project \(project.name.rawValue) (id \(project.id))")
        }
        if let manifest {
            lines += describe(manifest, buildSystem: ProjectBuildSystem.read(in: root))
        } else {
            lines.append("- \(ProjectBuildSystem.manifestFile) is missing or does not read as JSON.")
        }
        lines.append("- Git: " + (repository.map { gitState($0, root: root.path) } ?? gitState(root.path)))
        let tree = ProjectTree(root: root.path)
        if tree.lines.isEmpty {
            lines.append("Files: none.")
        } else {
            lines.append("Files (folders end in /, links in @, … marks what is not listed; .git, Builds and ignored paths are left out):")
            lines += tree.lines
            if tree.truncated {
                lines.append("(The listing stops at \(ProjectTree.maximumEntries) entries; list or find shows the rest.)")
            }
        }
        lines.append(closingTag)
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func describe(_ manifest: JSONValue, buildSystem: ProjectBuildSystem) -> [String] {
        var lines: [String] = []
        var kind: [String] = []
        if let value = text(manifest["kind"]) {
            kind.append(value)
        }
        if let language = text(manifest["language"]) {
            kind.append(["c": "C", "objc": "Objective-C", "swift": "Swift"][language] ?? language)
        }
        if let target = text(manifest["deploymentTarget"]) {
            kind.append("deployment target \(target)")
        }
        if case let .object(architectures)? = manifest["architectures"] {
            let list = architectures.keys.sorted().prefix(maximumListed).compactMap { bootstrap -> String? in
                guard case let .array(values)? = architectures[bootstrap] else { return nil }
                return ([ProjectTree.printable(bootstrap)] + values.prefix(maximumListed).compactMap(text))
                    .joined(separator: " ")
            }
            if !list.isEmpty {
                kind.append("architectures " + list.joined(separator: ", "))
            }
        }
        if !kind.isEmpty {
            lines.append("- Kind: " + kind.joined(separator: "; "))
        }
        if let template = manifest["template"] {
            let parts = ["extensionID", "templateID", "version"].compactMap { text(template[$0]) }
            if !parts.isEmpty {
                lines.append("- Template: " + parts.joined(separator: " "))
            }
        }
        switch buildSystem {
        case .external:
            lines.append("- Build: external. No Apelin build description; build with the project's own tools through shell_run.")
        case .apelin:
            var build = "Apelin's build tool"
            if case let .array(steps)? = manifest.value(at: "build.steps") {
                build += ", \(steps.count) steps"
            } else {
                build += "; the build description is missing"
            }
            if case let .array(products)? = manifest["products"], !products.isEmpty {
                build += "; products " + products.prefix(maximumListed).compactMap { product -> String? in
                    guard let id = text(product["id"]) else { return nil }
                    return text(product["type"]).map { "\(id) (\($0))" } ?? id
                }.joined(separator: ", ")
            }
            lines.append("- Build: " + build)
        }
        let package = ["id", "version"].compactMap { text(manifest.value(at: "package.\($0)")) }
        if !package.isEmpty {
            lines.append("- Package: " + package.joined(separator: " "))
        }
        let toolchain = text(manifest.value(at: "environment.toolchain.id"))
        let sdk = text(manifest.value(at: "environment.sdk.id"))
        if toolchain != nil || sdk != nil {
            lines.append("- Binds toolchain \(toolchain ?? "none") and SDK \(sdk ?? "none"); # Environment says whether they are here.")
        }
        return lines
    }

    /// A manifest string on one line, cut to `maximumFieldLength`: the
    /// manifest is the project's, whatever it holds.
    private static func text(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue else { return nil }
        let line = ProjectTree.printable(string)
        return line.count > maximumFieldLength ? String(line.prefix(maximumFieldLength)) + "…" : line
    }

    /// How many changed paths the line names before it counts the rest.
    static let maximumChangesListed = 12

    /// The repository as the host's `gitStatus` answered: its branch and
    /// commit, the changes as `git status --short` spells them, and the
    /// origin it would push to.
    static func gitState(_ status: GitStatusToolResponse, root: String) -> String {
        var line = switch (status.branch, status.head) {
        case let (branch?, head?): "on branch \(ProjectTree.printable(branch)) at \(head.prefix(7))"
        case let (branch?, nil): "on branch \(ProjectTree.printable(branch)), no commits yet"
        case let (nil, head?): "detached at \(head.prefix(7))"
        case (nil, nil): "a repository"
        }
        if status.entries.isEmpty {
            line += "; nothing to commit"
        } else {
            let listed = status.entries.prefix(maximumChangesListed).map { entry in
                let index = entry.index.isEmpty ? " " : entry.index
                let worktree = entry.worktree.isEmpty ? " " : entry.worktree
                return "\(index)\(worktree) \(ProjectTree.printable(entry.path))"
            }
            let more = status.entries.count - listed.count
            line += "; \(status.entries.count) changed: " + listed.joined(separator: ", ")
                + (more > 0 ? ", and \(more) more" : "")
        }
        if let origin = originURL(root) {
            line += "; origin \(origin)"
        }
        return line + "."
    }

    /// `remote.origin.url` from `.git/config`, read as text, without any
    /// user or password a URL might carry; nil when there is none.
    static func originURL(_ root: String) -> String? {
        guard let config = read(root + "/.git/config", limit: 64 << 10) else { return nil }
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
                continue
            }
            guard inOrigin, line.hasPrefix("url") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" else { continue }
            let url = parts[1].trimmingCharacters(in: .whitespaces)
            guard var components = URLComponents(string: url), components.host != nil else {
                return ProjectTree.printable(String(url.prefix(200)))
            }
            components.user = nil
            components.password = nil
            return components.string.map { ProjectTree.printable(String($0.prefix(200))) }
        }
        return nil
    }

    /// The repository in one line, read from `.git` itself without running
    /// anything, when the host did not answer; git_status has the rest.
    static func gitState(_ root: String) -> String {
        var metadata = stat()
        guard lstat(root + "/.git", &metadata) == 0 else { return "none; the project is not a repository (git_init makes one)." }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            return "a linked checkout (.git is not a folder); git_status has its state."
        }
        guard let head = read(root + "/.git/HEAD", limit: 4096)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty
        else { return "a repository whose HEAD does not read; git_status has its state." }
        if head.hasPrefix("ref: refs/heads/") {
            let branch = String(head.dropFirst("ref: refs/heads/".count))
            var reference = stat()
            let committed = lstat(root + "/.git/refs/heads/" + branch, &reference) == 0
                || (read(root + "/.git/packed-refs", limit: 4 << 20)?.contains(" refs/heads/\(branch)\n") ?? false)
            return "on branch \(ProjectTree.printable(branch))" + (committed ? "; git_status has the changes." : ", no commits yet.")
        }
        if head.count >= 7, head.allSatisfy(\.isHexDigit) {
            return "detached at \(head.prefix(7)); git_status has the changes."
        }
        return "a repository; git_status has its state."
    }

    /// `apelin-project.json` when it is a regular file inside the project
    /// that reads as JSON.
    private static func manifest(in root: ScopedRoot) -> JSONValue? {
        guard let path = try? root.resolveExisting(ProjectBuildSystem.manifestFile),
              let text = read(path, limit: maximumManifestBytes)
        else { return nil }
        return try? JSONCoding.decode(JSONValue.self, from: Data(text.utf8))
    }

    /// A regular file, not through a link, when it is no larger than `limit`.
    private static func read(_ path: String, limit: Int) -> String? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= off_t(limit)
        else { return nil }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
