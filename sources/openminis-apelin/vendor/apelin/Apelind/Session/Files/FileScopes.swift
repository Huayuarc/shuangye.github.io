import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// `fileRead{scopeID, relativePath}`: the host resolves the scope to a root,
/// the relative path inside it, and answers a read-only descriptor. Every
/// decision is made on canonical paths, and again on where the opened
/// descriptor actually is (`F_GETPATH`), so a folder mobile swapped for a link
/// between the check and the open cannot lead the host elsewhere.
///
/// | scope | root |
/// |---|---|
/// | a project ID, or `project:<name>` | `~/Documents/wiki.qaq.apelin/Projects/<name>/` |
/// | `sdk:<id>` | `~/Documents/wiki.qaq.apelin/SDKs/<id>/` |
/// | `extension:<id>` | `<install root>/usr/share/apelin/development/<id>/` |
/// | `agent-tools:<id>` | `<install root>/usr/share/apelin/agent-tools/<id>/` |
/// | `grant:<grantID>` | the one file a protected-edit grant names (app only) |
struct FileScopes: Sendable {
    let installRoot: String
    let dataFolder: DataFolder

    enum Scope: Equatable {
        case directory(String)
        case grant(String)
    }

    func resolve(_ scopeID: String, caller: Caller) throws -> Scope {
        guard !CanonicalPath.containsNUL(scopeID), !scopeID.isEmpty else {
            throw ApelinError(.badRequest, "the scope is empty or contains a NUL byte")
        }
        let root = installRoot == "/" ? "" : installRoot
        if let id = Self.suffix(scopeID, "grant:") {
            guard caller == .app else { throw ApelinError(.denied, "only the app can use a protected-edit grant") }
            return .grant(id)
        }
        if let id = Self.suffix(scopeID, "sdk:") {
            return try .directory(component(dataFolder.sdks.path, id))
        }
        if let id = Self.suffix(scopeID, "extension:") {
            return try .directory(component(root + "/usr/share/apelin/development", id))
        }
        if let id = Self.suffix(scopeID, "agent-tools:") {
            return try .directory(component(root + "/usr/share/apelin/agent-tools", id))
        }
        if let name = Self.suffix(scopeID, "project:") {
            guard ProjectName.validate(name) == nil else {
                throw ApelinError(.badRequest, "not a project name: \(name)")
            }
            return .directory(dataFolder.projects.appendingPathComponent(name).path)
        }
        guard let directory = projectDirectory(id: scopeID) else {
            throw ApelinError(.notFound, "no project with ID \(scopeID)")
        }
        return .directory(directory)
    }

    /// The project whose `apelin-project.json` carries this `projectID`.
    func projectDirectory(id: String) -> String? {
        let projects = dataFolder.projects
        let names = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        for name in names.sorted() where ProjectName.validate(name) == nil {
            let manifest = projects.appendingPathComponent(name).appendingPathComponent("apelin-project.json")
            guard let data = try? Data(contentsOf: manifest), data.count < 1 << 20,
                  let json = try? JSONCoding.decode(JSONValue.self, from: data),
                  json["projectID"]?.stringValue == id else { continue }
            return projects.appendingPathComponent(name).path
        }
        return nil
    }

    /// Opens `relativePath` inside `directory`, read-only.
    static func open(_ relativePath: String, inside directory: String) throws -> (OwnedDescriptor, String) {
        guard let root = CanonicalPath.resolve(directory) else {
            throw ApelinError(.notFound, "the scope's folder does not exist")
        }
        guard !relativePath.isEmpty, relativePath != "." else {
            throw ApelinError(.badRequest, "name a file inside the scope")
        }
        guard CanonicalPath.isPlainRelative(relativePath) else {
            throw ApelinError(.badRequest, "\(relativePath) is not a plain relative path")
        }
        let joined = root + "/" + relativePath
        guard let canonical = CanonicalPath.resolve(joined), CanonicalPath.isCanonical(canonical, inside: root) else {
            throw ApelinError(.denied, "\(relativePath) leads outside the scope")
        }
        return try openRegular(canonical, inside: root)
    }

    static func openRegular(_ canonical: String, inside root: String) throws -> (OwnedDescriptor, String) {
        let descriptor = Darwin.open(canonical, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ApelinError(.notFound, "\(canonical): \(String(cString: strerror(errno)))")
        }
        let owned = OwnedDescriptor(adopting: descriptor)
        guard let opened = Self.descriptorPath(descriptor), CanonicalPath.isCanonical(opened, inside: root) else {
            throw ApelinError(.denied, "the file moved outside the scope while it was opened")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw ApelinError(.badRequest, "\(canonical) is not a regular file")
        }
        return (owned, opened)
    }

    static func descriptorPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return CanonicalPath.resolve(String(cString: buffer))
    }

    static func version(of descriptor: Int32) -> FileVersion {
        var metadata = stat()
        fstat(descriptor, &metadata)
        let digest = metadata.st_size <= ProtectedEditPolicy.maximumBytes
            ? try? ProtectedEditPolicy.sha256(descriptor: descriptor)
            : nil
        return ProtectedEditPolicy.version(metadata, sha256: digest)
    }

    private func component(_ base: String, _ id: String) throws -> String {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != "..", !id.hasPrefix(".") else {
            throw ApelinError(.badRequest, "not an ID: \(id)")
        }
        return base + "/" + id
    }

    private static func suffix(_ value: String, _ prefix: String) -> String? {
        value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : nil
    }
}
