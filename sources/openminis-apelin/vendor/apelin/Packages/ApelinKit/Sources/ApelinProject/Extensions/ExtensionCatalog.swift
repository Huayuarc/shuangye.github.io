import ApelinCore
import Foundation

/// One extension found under the development directory: usable, or
/// isolated with the reasons the Settings page shows.
public struct DiscoveredExtension: Sendable, Equatable {
    /// The folder name (which a valid manifest's `id` equals).
    public var folderName: String
    /// The folder, as found under the install root.
    public var root: URL
    /// Nil when the manifest did not even parse or validate.
    public var manifest: ExtensionManifest?
    /// Empty when the extension is usable.
    public var problems: [String]

    public var isUsable: Bool {
        manifest != nil && problems.isEmpty
    }
}

/// Development extensions installed at
/// `<install-root>/usr/share/apelin/development/<id>/` (Milestone 1 §5.2):
/// each manifest is validated on its own, and a bad manifest, an unknown
/// schema version, a path escaping the extension, an undeclared or
/// symlinked template file, a stale template digest or a duplicate id
/// isolates that extension alone. A duplicate isolates both: nothing found
/// later overrides what was found first. Nothing named in a manifest runs.
public struct ExtensionCatalog: Sendable {
    public static func directory(installRoot: String) -> URL {
        let base = installRoot == "/" ? "" : installRoot
        return URL(fileURLWithPath: base + "/usr/share/apelin/development", isDirectory: true)
    }

    public let directory: URL
    public let extensions: [DiscoveredExtension]

    public init(directory: URL) {
        self.directory = directory
        extensions = Self.scan(directory)
    }

    public var usable: [DiscoveredExtension] {
        extensions.filter(\.isUsable)
    }

    public func usableExtension(_ id: String) -> DiscoveredExtension? {
        usable.first { $0.manifest?.id == id }
    }

    /// `<extension-id>/<template-id>`.
    public func template(
        _ qualifiedID: String,
    ) -> (DiscoveredExtension, ExtensionManifest, ExtensionManifest.Template)? {
        let parts = qualifiedID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let found = usableExtension(String(parts[0])), let manifest = found.manifest,
              let template = manifest.template(String(parts[1])) else { return nil }
        return (found, manifest, template)
    }

    private static func scan(_ directory: URL) -> [DiscoveredExtension] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        var found: [DiscoveredExtension] = []
        for name in names {
            let root = directory.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(root.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFLNK {
                found.append(DiscoveredExtension(
                    folderName: name,
                    root: root,
                    manifest: nil,
                    problems: ["\(name) is a symbolic link"],
                ))
                continue
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            found.append(inspect(name: name, root: root))
        }
        var counts: [String: Int] = [:]
        for item in found {
            if let id = item.manifest?.id {
                counts[id, default: 0] += 1
            }
        }
        return found.map { item in
            guard let id = item.manifest?.id, let count = counts[id], count > 1 else { return item }
            var isolated = item
            isolated.problems.append("another extension has the id \(id); both are set aside")
            return isolated
        }
    }

    /// Everything the IDE checks about one extension folder.
    public static func inspect(name: String, root: URL) -> DiscoveredExtension {
        let document: JSONDocument
        do {
            document = try StrictJSON.parse(ProjectFiles.read("manifest.json", in: root))
        } catch {
            return DiscoveredExtension(
                folderName: name,
                root: root,
                manifest: nil,
                problems: ["manifest.json: \(error)"],
            )
        }
        if let version = document["schemaVersion"], version != .integer(1) {
            return DiscoveredExtension(
                folderName: name,
                root: root,
                manifest: nil,
                problems: ["manifest schema version \(version) is not one this Apelin reads"],
            )
        }
        var problems = ManifestValidation.errors(document)
        guard problems.isEmpty, let manifest = try? ExtensionManifest(document: document) else {
            return DiscoveredExtension(
                folderName: name,
                root: root,
                manifest: nil,
                problems: problems.isEmpty ? ["manifest.json does not decode"] : problems,
            )
        }
        if manifest.id != name {
            problems.append("id \(manifest.id) differs from the folder name")
        }
        if !manifest.apelinCompatibility.projectSchemaVersions.contains(ProjectStore.projectSchemaVersion) {
            problems.append("its templates are for project schema \(manifest.apelinCompatibility.projectSchemaVersions), not \(ProjectStore.projectSchemaVersion)")
        }
        for license in manifest.licenses where (try? ProjectFiles.read(license.path, in: root)) == nil {
            problems.append("license \(license.path) is missing")
        }
        for (componentName, component) in manifest.support ?? [:] {
            for directory in component.includeDirectories ?? [] where !isDirectory(directory, in: root) {
                problems.append("support \(componentName): \(directory) is missing")
            }
            for bootstrap in Bootstrap.allCases {
                if let directory = component.linkStubDirectories?[bootstrap], !isDirectory(directory, in: root) {
                    problems.append("support \(componentName): \(directory) is missing")
                }
            }
        }
        if problems.isEmpty {
            for template in manifest.templates {
                problems += checkTemplate(extensionRoot: root, template: template)
            }
        }
        return DiscoveredExtension(folderName: name, root: root, manifest: manifest, problems: problems)
    }

    private static func isDirectory(_ relative: String, in root: URL) -> Bool {
        guard let real = try? ProjectFiles.resolve(relative, in: root) else { return false }
        var info = stat()
        return stat(real, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// `check_template`: every file declared and nothing else, no symlink,
    /// placeholder types legal for each format and path, defaults valid, and
    /// the digest current.
    public static func checkTemplate(extensionRoot: URL, template: ExtensionManifest.Template) -> [String] {
        var errors: [String] = []
        let root = extensionRoot.appendingPathComponent(template.directory, isDirectory: true)
        guard (try? ProjectFiles.resolve(template.directory, in: extensionRoot)) != nil else {
            return ["\(template.id): \(template.directory) is missing or outside the extension"]
        }
        let types = TemplateParameters.types(for: template)
        let declared = Set(template.files.map(\.path))
        var onDisk: Set<String> = []
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            while let relative = walker.nextObject() as? String {
                let full = root.appendingPathComponent(relative).path
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFLNK {
                    errors.append("\(template.id): \(relative) is a symbolic link")
                    onDisk.insert(relative)
                } else if kind != S_IFDIR {
                    onDisk.insert(relative)
                }
            }
        }
        for missing in declared.subtracting(onDisk).sorted() {
            errors.append("\(template.id): \(missing) is listed but missing")
        }
        for extra in onDisk.subtracting(declared).sorted() {
            errors.append("\(template.id): \(extra) is not listed in the manifest")
        }
        for file in template.files {
            let location = "\(template.id)/\(file.path)"
            errors += TemplateParameters.checkPath(file.path, types: types, where: location)
            guard onDisk.contains(file.path), let data = try? ProjectFiles.read(file.path, in: root) else { continue }
            if file.format != "copy" {
                guard let text = String(data: data, encoding: .utf8) else {
                    errors.append("\(location): not UTF-8; use format copy")
                    continue
                }
                errors += TemplateParameters.checkText(text, format: file.format, types: types, where: location)
            }
        }
        for parameter in template.parameters {
            if let value = parameter.default?.value {
                do {
                    try TemplateParameters.validate(parameter.name, types[parameter.name]!, value)
                } catch {
                    errors.append("\(template.id): default \(error)")
                }
            }
        }
        if errors.isEmpty {
            do {
                let actual = try TemplateDigest.compute(templateRoot: root, files: template.files)
                if actual != template.digest {
                    errors.append("\(template.id): digest is \(actual), manifest says \(template.digest)")
                }
            } catch {
                errors.append("\(template.id): \(error)")
            }
        }
        return errors
    }
}
