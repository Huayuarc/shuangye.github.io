import ApelinCore
import ApelinProtocol
import Foundation

/// Finds projects in `~/Documents/wiki.qaq.apelin/Projects/<name>/`, the only
/// place one lives, and reads what they are bound to.
///
/// A project is named on the wire by the `projectID` in its
/// `apelin-project.json`; a folder with no description yet (a fresh clone)
/// is named by its folder name. Either way the answer is a folder whose
/// realpath is exactly one component below the realpath of `Projects/`.
public struct ProjectLocator: Sendable {
    public let layout: EnvironmentLayout

    public init(layout: EnvironmentLayout) {
        self.layout = layout
    }

    public struct Project: Sendable, Equatable {
        public var name: String
        public var root: URL
        public var projectID: String?
        /// The description's `kind`: `workspace` for an empty workspace,
        /// else the template's extension kind.
        public var kind: String?
        public var toolchainID: String?
        public var sdkID: String?
    }

    /// The canonical `Projects/` folder, or nil when there is none yet.
    func canonicalProjects() -> String? {
        CanonicalPath.resolve(layout.data.projects.path)
    }

    /// Every project folder, with what its description says.
    public func all() -> [Project] {
        guard let projects = canonicalProjects(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: projects)
        else { return [] }
        return names.sorted().compactMap { name in
            guard ProjectName.validate(name) == nil else { return nil }
            return project(named: name, under: projects)
        }
    }

    /// The project named by `projectID` (a project ID or, failing that, a
    /// folder name).
    public func locate(_ projectID: String) throws -> Project {
        guard !CanonicalPath.containsNUL(projectID), !projectID.isEmpty else {
            throw ApelinError(.badRequest, "no project ID")
        }
        let all = all()
        if let match = all.first(where: { $0.projectID == projectID }) {
            return match
        }
        if ProjectName.validate(projectID) == nil, let match = all.first(where: { $0.name == projectID }) {
            return match
        }
        throw ApelinError(.notFound, "no project \(projectID.debugDescription)")
    }

    /// The folder a new project named `name` would have; refuses a bad name
    /// and one that exists.
    public func newProjectRoot(named name: String) throws -> URL {
        if let problem = ProjectName.validate(name) {
            throw ApelinError(.badRequest, problem.reason)
        }
        try layout.make(layout.data.projects)
        guard let projects = canonicalProjects() else { throw ApelinError(.unavailable, "no Projects folder") }
        let root = URL(fileURLWithPath: projects, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        var metadata = stat()
        guard lstat(root.path, &metadata) != 0 else { throw ApelinError(.conflict, "a project named \(name) exists") }
        return root
    }

    /// A path inside a project, relative to its root: plain (no `..`, not
    /// absolute, no NUL), and — when it exists — resolving inside the root;
    /// when it does not exist (a deleted file being staged), its nearest
    /// existing parent must.
    public func checkRelative(_ path: String, in project: Project) throws -> String {
        guard CanonicalPath.isPlainRelative(path) else {
            throw ApelinError(.badRequest, "\(path.debugDescription) is not a path inside the project")
        }
        guard let root = CanonicalPath.resolve(project.root.path) else {
            throw ApelinError(.notFound, "the project folder no longer exists")
        }
        var candidate = project.root.appendingPathComponent(path)
        while true {
            var metadata = stat()
            if lstat(candidate.path, &metadata) == 0 {
                // A symlink is checked by where it points, but git records the
                // link itself; a link leading out is refused all the same.
                guard let resolved = CanonicalPath.resolve(candidate.path),
                      CanonicalPath.isCanonical(resolved, inside: root)
                else {
                    throw ApelinError(.denied, "\(path) leads outside the project")
                }
                return path
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path,
                  CanonicalPath.isCanonical(parent.standardizedFileURL.path, inside: project.root.path)
            else {
                return path
            }
            candidate = parent
        }
    }

    /// Projects whose description binds the SDK `id`.
    public func projects(usingSDK id: String) -> [String] {
        all().filter { $0.sdkID == id }.map(\.name)
    }

    /// Projects whose description binds the toolchain `id`.
    public func projects(usingToolchain id: String) -> [String] {
        all().filter { $0.toolchainID == id }.map(\.name)
    }

    private func project(named name: String, under projects: String) -> Project? {
        let root = URL(fileURLWithPath: projects, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        guard let resolved = CanonicalPath.resolve(root.path),
              CanonicalPath.isCanonical(resolved, inside: projects),
              CanonicalPath.components(resolved).count == CanonicalPath.components(projects).count + 1
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        var project = Project(name: name, root: URL(fileURLWithPath: resolved, isDirectory: true))
        let description = URL(fileURLWithPath: resolved).appendingPathComponent("apelin-project.json")
        if let data = FileManager.default.contents(atPath: description.path),
           let json = try? JSONCoding.decode(JSONValue.self, from: data)
        {
            project.projectID = json["projectID"]?.stringValue
            project.kind = json["kind"]?.stringValue
            project.toolchainID = json.value(at: "environment.toolchain.id")?.stringValue
            project.sdkID = json.value(at: "environment.sdk.id")?.stringValue
        }
        return project
    }
}
