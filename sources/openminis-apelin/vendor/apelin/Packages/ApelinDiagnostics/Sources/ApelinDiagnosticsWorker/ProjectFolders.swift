import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// A project's folder, found as mobile by the `projectID` in its
/// `apelin-project.json`, under `~/Documents/wiki.qaq.apelin/Projects/` and
/// nowhere else. Canonical paths, compared by component.
enum ProjectFolders {
    /// Where a project's dSYMs are: apelin-build keeps each build's outputs in
    /// `Builds/<projectID>/<buildID>/`, outside the project; the project
    /// folder is read too, for dSYMs a user put there.
    static func dsymDirectories(projectID: String, home: String) throws -> [URL] {
        let project = try find(projectID: projectID, home: home).url
        guard projectID.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95 }) else {
            return [project]
        }
        let data = DataFolder(home: home).root
        let builds = data
            .appendingPathComponent("Builds", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
        guard let root = CanonicalPath.resolve(data.path),
              let resolved = CanonicalPath.resolve(builds.path), CanonicalPath.isCanonical(resolved, inside: root)
        else { return [project] }
        return [URL(fileURLWithPath: resolved, isDirectory: true), project]
    }

    static func manifest(projectID: String, home: String) throws -> JSONValue {
        try find(projectID: projectID, home: home).manifest
    }

    /// What a build recorded for `confirmLoaded` in its artifact record,
    /// `Builds/artifacts/<buildID>.json`: a workspace's build reads it from
    /// the package it made (ApelinBuild's `ExternalBuild`). Nil when there
    /// is none.
    static func loadCheck(buildID: String, home: String) -> BuildLoadCheck? {
        guard !buildID.isEmpty, buildID.count <= 128,
              buildID.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 })
        else { return nil }
        let path = DataFolder(home: home).root
            .appendingPathComponent("Builds/artifacts/\(buildID).json").path
        return read(path)?["loadCheck"].flatMap { try? $0.decode(BuildLoadCheck.self) }
    }

    private static func find(projectID: String, home: String) throws -> (url: URL, manifest: JSONValue) {
        guard !projectID.isEmpty, !CanonicalPath.containsNUL(projectID) else {
            throw ApelinError(.badRequest, "projectID must not be empty or contain NUL.")
        }
        guard let root = CanonicalPath.resolve(DataFolder(home: home).projects.path) else {
            throw ApelinError(.notFound, "There is no Projects folder yet. Create a project first.")
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for name in names.sorted() where ProjectName.validate(name) == nil {
            guard let path = CanonicalPath.resolve(root + "/" + name),
                  CanonicalPath.isCanonical(path, inside: root),
                  CanonicalPath.components(path).count == CanonicalPath.components(root).count + 1,
                  let manifest = read(path + "/apelin-project.json"),
                  manifest["projectID"]?.stringValue == projectID
            else { continue }
            return (URL(fileURLWithPath: path, isDirectory: true), manifest)
        }
        throw ApelinError(.notFound, "No project has the ID \(projectID).")
    }

    private static func read(_ path: String) -> JSONValue? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 1 << 20 else { return nil }
        return try? JSONCoding.decode(JSONValue.self, from: handle.readDataToEndOfFile())
    }
}

/// What `confirmLoaded` looks for, read from `apelin-project.json`: the
/// marker the template logs (`ApelinLoaded <APELIN_BUILD_ID>` under the
/// package id's subsystem), where the package installs the tweak's dylib on
/// this bootstrap, and the filter plist the packager writes beside it.
struct LoadPlan: Equatable {
    var marker: String
    var subsystem: String?
    var dylibPath: String
    var filterPlist: Data?

    /// From what a workspace's build recorded: the dylib where this device
    /// installs it, and the filter its package carried.
    static func from(loadCheck check: BuildLoadCheck) -> LoadPlan {
        var dictionary: [String: Any] = [:]
        for (values, name) in [(check.bundles, "Bundles"), (check.executables, "Executables"), (check.classes, "Classes")]
            where !values.isEmpty
        {
            dictionary[name] = values
        }
        return LoadPlan(
            marker: check.marker,
            subsystem: check.markerSubsystem,
            dylibPath: check.dylibInstalledPath,
            filterPlist: dictionary.isEmpty ? nil : try? PropertyListSerialization.data(
                fromPropertyList: ["Filter": dictionary],
                format: .xml,
                options: 0,
            ),
        )
    }

    static func from(manifest: JSONValue, buildID: String, installRoot: String) throws -> LoadPlan {
        let package = manifest["package"]
        var plan = LoadPlan(
            marker: BuildLoadCheck.marker(buildID: buildID),
            subsystem: package?["id"]?.stringValue,
            dylibPath: "",
            filterPlist: nil,
        )
        guard let filter = package?["tweakFilter"], let product = filter["dylib"]?.stringValue else { return plan }
        if case let .array(layout)? = package?["layout"],
           let entry = layout.first(where: { $0["product"]?.stringValue == product }),
           let logical = entry["path"]?.stringValue, logical.hasPrefix("/"), !logical.contains("\0"),
           !CanonicalPath.components(logical).contains("..")
        {
            plan.dylibPath = installRoot == "/" ? logical : installRoot + logical
        }
        var dictionary: [String: Any] = [:]
        for (key, name) in [("bundles", "Bundles"), ("executables", "Executables"), ("classes", "Classes")] {
            if case let .array(values)? = filter[key] {
                dictionary[name] = values.compactMap(\.stringValue)
            }
        }
        if !dictionary.isEmpty {
            plan.filterPlist = try? PropertyListSerialization.data(
                fromPropertyList: ["Filter": dictionary],
                format: .xml,
                options: 0,
            )
        }
        return plan
    }
}
