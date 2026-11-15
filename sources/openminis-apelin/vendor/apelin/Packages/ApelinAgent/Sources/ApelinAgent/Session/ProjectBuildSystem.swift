import Foundation

/// Who builds the project, read from its `apelin-project.json`: Apelin's
/// build tool from the build description, or the project's own tools.
enum ProjectBuildSystem: Equatable {
    /// `buildStart` from the manifest's configurations and products.
    case apelin
    /// A workspace: `kind` is `workspace` or `buildSystem` is `external`. A
    /// workspace written before `buildSystem` existed has neither recipe nor
    /// field, so it is external too.
    case external

    static let manifestFile = "apelin-project.json"
    static let maxManifestBytes = 1 << 20

    /// Read again on every call, so a manifest the agent or the user edits
    /// counts from the next prompt. A manifest that is missing, too large or
    /// not JSON is Apelin's: the build tool then reports what is wrong.
    static func read(in root: ScopedRoot) -> ProjectBuildSystem {
        guard let manifest = manifest(in: root) else { return .apelin }
        if manifest["kind"] as? String == "workspace" || manifest["buildSystem"] as? String == "external" {
            return .external
        }
        return .apelin
    }

    /// The script a workspace declares it builds with (`external.script`,
    /// apelin-build's `ExternalBuildDeclaration`), as written; nil when it
    /// declares none. apelin-build checks the declaration itself.
    static func externalScript(in root: ScopedRoot) -> String? {
        guard let external = manifest(in: root)?["external"] as? [String: Any],
              let script = external["script"] as? String, !script.isEmpty else { return nil }
        return script
    }

    /// The manifest as JSON; nil when it is missing, not a regular file,
    /// larger than `maxManifestBytes` or not a JSON object.
    static func manifest(in root: ScopedRoot) -> [String: Any]? {
        guard let path = try? root.resolveExisting(manifestFile),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxManifestBytes + 1), data.count <= maxManifestBytes else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// What apelin_project_build answers on a workspace that declares no build,
    /// instead of the build worker's error about a description the
    /// workspace never had.
    static let externalBuildRefusal = "This workspace declares no build yet. Write a script in the project that builds the package with the repository's own tools and writes one .deb into $APELIN_PACKAGE_DIR, then declare it in apelin-project.json as \"external\": {\"script\": \"<its path>\"}; read the apelin-external-build skill first."
}
