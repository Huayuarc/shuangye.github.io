import ApelinCore
import ApelinProject
import ApelinProtocol
import Foundation

/// What `projectCheck` adds for `purpose: distribution`: what a package
/// meant for other people should not carry. A template's placeholder name,
/// description or author, its first version, an identifier `projectCreate`
/// made up, an app without an icon, a version this project already packaged
/// for the target. Every finding is a warning with a `distribution.*` code,
/// so the build is never refused for one; the app asks before packaging
/// and the agent is told what to change.
public struct DistributionCheck: Sendable {
    public var store: ProjectStore
    public var catalog: ExtensionCatalog

    /// The prefix `projectCreate` gives identifiers nobody chose.
    static let localPrefix = "local.apelin."

    /// The Info.plist keys any of which names an app's icon.
    static let iconKeys = [
        "CFBundleIcons",
        "CFBundleIcons~ipad",
        "CFBundleIconFiles",
        "CFBundleIconFile",
        "CFBundleIconName",
    ]

    public init(store: ProjectStore, catalog: ExtensionCatalog) {
        self.store = store
        self.catalog = catalog
    }

    /// Nothing when the project does not read: `ProjectCheck` reports that.
    public func run(projectID: String, bootstrap: Bootstrap?) -> [ProjectDiagnostic] {
        guard let (_, root) = try? store.root(of: projectID),
              let data = try? ProjectFiles.read(ProjectStore.projectFileName, in: root),
              let document = try? StrictJSON.parse(data),
              let project = try? ProjectDocument(document: document)
        else { return [] }
        var out: [ProjectDiagnostic] = []
        func warn(_ code: String, _ field: String, _ message: String, file: String = ProjectStore.projectFileName) {
            out.append(ProjectDiagnostic(code: code, severity: .warning, message: message, file: file, field: field))
        }

        let package = project.package
        let template = templateDefaults(project.template)
        for (code, field, value, purpose) in [
            ("distribution.package.name.template", "/package/name", package.name, "the name people see in their package manager"),
            ("distribution.package.description.template", "/package/description", package.description, "what the package does"),
            ("distribution.package.author.template", "/package/author", package.author, "who made it"),
        ] where template.placeholders.contains(value) {
            warn(code, field, "\(field) is still the template's “\(value)”; write \(purpose)")
        }
        if let initial = template.version, package.version == initial {
            warn(
                "distribution.package.version.template",
                "/package/version",
                "/package/version is still the template's \(initial); give the first release its own version",
            )
        }
        if package.id.hasPrefix(Self.localPrefix) {
            warn(
                "distribution.package.id.local",
                "/package/id",
                "/package/id \(package.id) is the local identifier Apelin made up; use a reverse-DNS identifier you own",
            )
        }

        for (index, product) in project.products.enumerated() where product.type == .app {
            guard let path = product.infoPlist,
                  let contents = try? ProjectFiles.read(path, in: root),
                  let plist = (try? PropertyListSerialization.propertyList(from: contents, format: nil)) as? [String: Any]
            else { continue }
            if let identifier = plist["CFBundleIdentifier"] as? String, identifier.hasPrefix(Self.localPrefix) {
                warn(
                    "distribution.bundleID.local",
                    "/products/\(index)/infoPlist",
                    "\(path) gives the app the local bundle identifier \(identifier); use a reverse-DNS identifier you own",
                    file: path,
                )
            }
            if !Self.iconKeys.contains(where: { plist[$0] != nil }) {
                warn(
                    "distribution.icon.missing",
                    "/products/\(index)/infoPlist",
                    "\(path) names no app icon (CFBundleIcons); the home screen and package managers show a blank one",
                    file: path,
                )
            }
        }

        let release = ConfigurationName.release.rawValue
        let packaged = ArtifactStore(store: store).all()
            .filter {
                $0.projectID == project.projectID && $0.configuration == release && $0.packageID == package.id
                    && $0.packageVersion == package.version && (bootstrap == nil || $0.bootstrap == bootstrap?.rawValue)
            }
            .max { $0.createdAt < $1.createdAt }
        if let packaged {
            let date = packaged.createdAt.formatted(.iso8601.year().month().day())
            warn(
                "distribution.version.packaged",
                "/package/version",
                "version \(package.version) was already packaged for \(packaged.bootstrap) on \(date): publish or share that "
                    + "package as it is; raise /package/version only to ship a change, so package managers offer it as an update",
            )
        }
        return out
    }

    /// What a workspace's release package carries that a package for other
    /// people should not, read off the package its script wrote
    /// (`ExternalBuild`), since a workspace has no description to read
    /// before it is built: the identifier Apelin makes up, a version this
    /// project already packaged for the target, and a package other than
    /// the one the other target's latest release carried. `record` is the
    /// new package's, before it is saved.
    public static func packageFindings(_ record: ArtifactRecord, store: ProjectStore) -> [ProjectDiagnostic] {
        var out: [ProjectDiagnostic] = []
        func warn(_ code: String, _ message: String) {
            out.append(ProjectDiagnostic(code: code, severity: .warning, message: message))
        }
        if record.packageID.hasPrefix(localPrefix) {
            warn(
                "distribution.package.id.local",
                "the package's identifier \(record.packageID) is the local one Apelin makes up; have the build script use a reverse-DNS identifier you own",
            )
        }
        let releases = ArtifactStore(store: store).all().filter {
            $0.projectID == record.projectID && $0.configuration == ConfigurationName.release.rawValue
                && $0.artifactID != record.artifactID
        }
        let packaged = releases
            .filter {
                $0.bootstrap == record.bootstrap && $0.packageID == record.packageID
                    && $0.packageVersion == record.packageVersion
            }
            .max { $0.createdAt < $1.createdAt }
        if let packaged {
            let date = packaged.createdAt.formatted(.iso8601.year().month().day())
            warn(
                "distribution.version.packaged",
                "version \(record.packageVersion) was already packaged for \(record.bootstrap) on \(date): publish or share that "
                    + "package as it is; raise the version the build script writes only to ship a change, so package managers offer it as an update",
            )
        }
        let other = releases.filter { $0.bootstrap != record.bootstrap }.max { $0.createdAt < $1.createdAt }
        if let other, other.packageID != record.packageID {
            warn(
                "distribution.package.id.differs",
                "this \(record.bootstrap) package is \(record.packageID), but the latest \(other.bootstrap) release was \(other.packageID); "
                    + "both targets should ship the same package",
            )
        }
        return out
    }

    /// The template's string parameter defaults and the version its project
    /// file starts with; nothing when the template is no longer installed.
    private func templateDefaults(
        _ source: ProjectDocument.TemplateSource,
    ) -> (placeholders: Set<String>, version: String?) {
        guard let (found, _, template) = catalog.template("\(source.extensionID)/\(source.templateID)") else {
            return ([], nil)
        }
        let placeholders = Set(
            template.parameters.filter { $0.type == "string" }.compactMap { $0.default?.value.stringValue },
        )
        let file = found.root.appendingPathComponent(template.directory).appendingPathComponent(template.project)
        // The project file is not JSON until it is filled in; its one
        // literal version is the package's.
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let version = text.range(of: #""version"\s*:\s*"[0-9][^"]*""#, options: .regularExpression)
            .flatMap { text[$0].split(separator: "\"").last.map(String.init) }
        return (placeholders.subtracting([""]), version)
    }
}
