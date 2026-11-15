import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// A project as the session host resolved it for an agent session: its id
/// from `apelin-project.json`, its folder name, and the canonical path of
/// `Projects/<name>` — checked by component, never by string prefix.
struct ResolvedProject: Sendable, Equatable {
    /// A temporary chat's workspace is this prefix and its UUID.
    static let temporaryIDPrefix = "temporary:"

    var id: String
    var name: String
    var path: String

    var isTemporary: Bool {
        id.hasPrefix(Self.temporaryIDPrefix)
    }
}

/// Finds a project under mobile's `Projects/` by id or by name. The host
/// reads what mobile wrote, so every step is canonicalised first and a
/// project folder that is a link out of `Projects/` is refused.
enum AgentProjects {
    private static let maximumManifestBytes = 1 << 20

    static func resolve(
        home: String,
        projectID: String?,
        projectName: String?,
        temporaryID: String? = nil,
    ) throws -> ResolvedProject {
        if let temporaryID {
            guard UUID(uuidString: temporaryID) != nil, projectID == nil, projectName == nil else {
                throw ApelinError(.badRequest, "a temporary chat names only its workspace UUID")
            }
            let folder = DataFolder(home: home).root.appendingPathComponent("Temporary").path
            guard let root = CanonicalPath.resolve(folder),
                  let path = CanonicalPath.resolve(folder + "/" + temporaryID),
                  CanonicalPath.isCanonical(path, inside: root),
                  CanonicalPath.components(path).count == CanonicalPath.components(root).count + 1
            else {
                throw ApelinError(.notFound, "This chat is no longer available. Start a new chat.")
            }
            return ResolvedProject(id: ResolvedProject.temporaryIDPrefix + temporaryID, name: temporaryID, path: path)
        }
        let projects = DataFolder(home: home).projects.path
        guard let root = CanonicalPath.resolve(projects) else {
            throw ApelinError(.notFound, "There is no Projects folder yet. Create a project first.")
        }
        if let projectName {
            guard ProjectName.validate(projectName) == nil else {
                throw ApelinError(.badRequest, "“\(projectName)” is not a valid project name.")
            }
            let project = try candidate(root: root, name: projectName)
            if let projectID, project.id != projectID {
                throw ApelinError(.conflict, "Projects/\(projectName) has a different project id")
            }
            return project
        }
        guard let projectID, !projectID.isEmpty else {
            throw ApelinError(.badRequest, "name the project with projectID or projectName")
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for name in names.sorted() where ProjectName.validate(name) == nil {
            if let project = try? candidate(root: root, name: name), project.id == projectID {
                return project
            }
        }
        throw ApelinError(.notFound, "no project has the id \(projectID)")
    }

    /// Every project under `Projects/`, by id, as `resolve` finds each by
    /// its id: the first folder by name when two share one.
    static func all(home: String) -> [String: ResolvedProject] {
        guard let root = CanonicalPath.resolve(DataFolder(home: home).projects.path) else { return [:] }
        var projects: [String: ResolvedProject] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for name in names.sorted() where ProjectName.validate(name) == nil {
            if let project = try? candidate(root: root, name: name), projects[project.id] == nil {
                projects[project.id] = project
            }
        }
        return projects
    }

    /// `Projects/<name>` whose canonical path is a direct child of the
    /// canonical `Projects`, with a readable `apelin-project.json`.
    private static func candidate(root: String, name: String) throws -> ResolvedProject {
        guard let path = CanonicalPath.resolve(root + "/" + name),
              CanonicalPath.isCanonical(path, inside: root),
              CanonicalPath.components(path).count == CanonicalPath.components(root).count + 1
        else {
            throw ApelinError(.notFound, "The project “\(name)” is no longer available.")
        }
        let manifest = try readManifest(path + "/apelin-project.json")
        guard let id = manifest["projectID"]?.stringValue, !id.isEmpty else {
            throw ApelinError(
                .badRequest,
                "The project “\(name)” cannot be opened. Its project details are incomplete.",
            )
        }
        return ResolvedProject(id: id, name: name, path: path)
    }

    /// Opens without following a link and reads a bounded regular file.
    static func readManifest(_ path: String) throws -> JSONValue {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ApelinError(.notFound, "This project cannot be opened. Its project details are missing.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= maximumManifestBytes
        else {
            throw ApelinError(.badRequest, "This project cannot be opened. Its project details could not be read.")
        }
        let data = handle.readDataToEndOfFile()
        do {
            return try JSONCoding.decode(JSONValue.self, from: data)
        } catch {
            throw ApelinError(.badRequest, "This project cannot be opened. Its project details could not be read.")
        }
    }
}
