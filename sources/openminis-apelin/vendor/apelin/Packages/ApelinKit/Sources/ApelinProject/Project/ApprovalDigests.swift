import ApelinCore
import Foundation

/// Reads a regular file that, after `realpath(3)`, is still under `root` by
/// component comparison: the reference implementation's `read_inside`, and
/// the rule every project path goes through before anything reads it.
public enum ProjectFiles {
    public struct Refused: Error, CustomStringConvertible, Sendable {
        public var description: String
    }

    /// The canonical path of `relative` under `root`, or why not.
    public static func resolve(_ relative: String, in root: URL) throws -> String {
        guard !CanonicalPath.containsNUL(relative) else { throw Refused(description: "embedded NUL") }
        guard let realRoot = CanonicalPath.resolve(root.path) else {
            throw Refused(description: "\(root.path) does not resolve")
        }
        guard let real = CanonicalPath.resolve(realRoot + "/" + relative) else {
            throw Refused(description: "\(relative) does not exist")
        }
        guard CanonicalPath.isCanonical(real, inside: realRoot), real != realRoot else {
            throw Refused(description: "\(relative) resolves outside \(root.path)")
        }
        return real
    }

    public static func read(_ relative: String, in root: URL) throws -> Data {
        let real = try resolve(relative, in: root)
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Refused(description: "\(relative) is not a regular file")
        }
        return try Data(contentsOf: URL(fileURLWithPath: real))
    }
}

/// The two descriptions Confirm mode compares and their digests
/// (Documents/Schemas/README.md ▸ Approval digests), cut from the parsed
/// document so formatting and member order never matter. Byte-identical to
/// `build_description`, `packaging_description` and `project_digests`.
public struct ApprovalDigests: Codable, Sendable, Equatable {
    public struct Description: Codable, Sendable, Equatable {
        /// The canonical JSON the digest is taken over; the host keeps it to
        /// render a diff against the next change.
        public var canonical: String
        public var digest: String

        /// The description's `files`: each file it names, as the project
        /// spells it, and the `sha256:` of the bytes it was digested over.
        public var files: [String: String] {
            let document = try? StrictJSON.parse(Data(canonical.utf8))
            var files: [String: String] = [:]
            for (path, digest) in document?["files"]?.objectValue?.entries ?? [] {
                files[path] = digest.stringValue
            }
            return files
        }
    }

    public var build: Description
    public var packaging: Description

    private static let buildMembers = ["kind", "language", "deploymentTarget", "architectures", "configurations"]
    private static let productInputMembers: Set<String> = ["sources", "headerSearchPaths", "resources"]

    public static func buildDescription(_ project: JSONDocument, root: URL) throws -> JSONDocument {
        guard case let .object(document) = project else { throw ProjectFiles.Refused(description: "not an object") }
        var selected = JSONObject()
        for member in buildMembers {
            if let value = document[member] {
                selected[member] = value
            }
        }
        let products = document["products"]?.arrayValue ?? []
        selected["products"] = .array(products.map { product in
            guard case let .object(object) = product else { return product }
            return .object(JSONObject(object.entries.filter { !productInputMembers.contains($0.key) }))
        })
        selected["build"] = document["build"] ?? .null
        var files = JSONObject()
        for product in products {
            if let path = product["entitlements"]?.stringValue {
                files[path] = try .string(CanonicalJSON.sha256Tag(ProjectFiles.read(path, in: root)))
            }
        }
        for step in document["build"]?["steps"]?.arrayValue ?? [] where step["type"]?.stringValue == "script" {
            if let path = step["file"]?.stringValue {
                files[path] = try .string(CanonicalJSON.sha256Tag(ProjectFiles.read(path, in: root)))
            }
        }
        return .object(JSONObject([
            ("description", .string("apelin.build")),
            ("version", .integer(1)),
            ("project", .object(selected)),
            ("files", .object(files)),
        ]))
    }

    public static func packagingDescription(_ project: JSONDocument, root: URL) throws -> JSONDocument {
        guard case let .object(document) = project, case let .object(package)? = document["package"] else {
            throw ProjectFiles.Refused(description: "no package")
        }
        let trimmed = JSONObject(package.entries.filter { $0.key != "version" })
        var files = JSONObject()
        for (_, path) in package["maintainerScripts"]?.objectValue?.entries ?? [] {
            if let path = path.stringValue {
                files[path] = try .string(CanonicalJSON.sha256Tag(ProjectFiles.read(path, in: root)))
            }
        }
        for entry in package["layout"]?.arrayValue ?? [] {
            if let path = entry["file"]?.stringValue {
                files[path] = try .string(CanonicalJSON.sha256Tag(ProjectFiles.read(path, in: root)))
            }
        }
        return .object(JSONObject([
            ("description", .string("apelin.packaging")),
            ("version", .integer(1)),
            ("project", .object(JSONObject([("kind", document["kind"] ?? .null), ("package", .object(trimmed))]))),
            ("files", .object(files)),
        ]))
    }

    /// Both digests of a validated project rooted at `root`. A referenced
    /// file that is missing, irregular or outside the project throws: the
    /// description is uncomputable, which blocks the build or install.
    public static func compute(_ project: JSONDocument, root: URL) throws -> ApprovalDigests {
        let build = try buildDescription(project, root: root)
        let packaging = try packagingDescription(project, root: root)
        return ApprovalDigests(
            build: Description(canonical: CanonicalJSON.string(build), digest: CanonicalJSON.digest(build)),
            packaging: Description(canonical: CanonicalJSON.string(packaging), digest: CanonicalJSON.digest(packaging)),
        )
    }

    /// Reads, validates and digests `<root>/apelin-project.json`.
    public static func compute(projectAt root: URL) throws -> ApprovalDigests {
        let (document, _) = try ProjectValidation.load(
            Data(contentsOf: root.appendingPathComponent(ProjectStore.projectFileName)),
        )
        return try compute(document, root: root)
    }
}
