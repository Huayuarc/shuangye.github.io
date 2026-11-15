import ApelinCore
import Foundation

/// How a project's package is built, read off its `apelin-project.json`:
/// apelin-build from the project's build description, or a workspace's own
/// script (`external`, apelin-build's `ExternalBuildDeclaration`). A
/// workspace — `kind: workspace`, or `buildSystem: external`, as the
/// agent's `ProjectBuildSystem` reads it — has no description; one that
/// declares no script, and a manifest of any other kind without a `build`,
/// have nothing to package yet. apelin-build's `projectCheck` judges the
/// declaration itself.
enum ProjectBuildMethod: Equatable {
    case description
    case script
    case missingDescription
    case missingScript

    /// The kinds apelin-build builds from a description.
    private static let buildableKinds: Set<String> = ["app", "tweak", "cli", "preferences"]

    init(manifest: JSONValue) {
        let kind = manifest["kind"]?.stringValue
        if kind == "workspace" || manifest["buildSystem"]?.stringValue == "external" {
            self = manifest["external"]?["script"]?.stringValue?.isEmpty == false ? .script : .missingScript
        } else if let kind, Self.buildableKinds.contains(kind), case .object? = manifest["build"] {
            self = .description
        } else {
            self = .missingDescription
        }
    }

    var canBuild: Bool {
        self == .description || self == .script
    }

    /// Why Distribute… is not offered, in a menu item's few words.
    var shortBlocker: String? {
        switch self {
        case .description, .script: nil
        case .missingDescription: String(localized: "Needs a build description")
        case .missingScript: String(localized: "Needs a build script")
        }
    }

    /// Why the distribution page has no target, and what to do about it.
    var blocker: String? {
        switch self {
        case .description, .script: nil
        case .missingDescription:
            String(localized: "This project needs a build description before it can be distributed. Ask your agent to add one.")
        case .missingScript:
            String(localized: "This workspace needs a build script before it can be distributed. Ask your agent to declare one that writes a package.")
        }
    }
}
