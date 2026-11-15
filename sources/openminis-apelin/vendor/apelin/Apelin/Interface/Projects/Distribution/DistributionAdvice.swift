import ApelinProtocol

/// A `distribution.*` finding in the reader's words: what the check before
/// a build lists, and what a workspace's release build finds in the
/// package its script wrote.
enum DistributionAdvice {
    /// A release package of this version was made for the target before:
    /// advice, never a reason to build again, since that build can be
    /// published or shared as it is.
    static let versionPackaged = "distribution.version.packaged"

    /// What the finding is, in the reader's words.
    static func title(of issue: ProjectDiagnostic) -> String {
        switch issue.code {
        case "distribution.package.name.template": String(localized: "The package still uses the template’s name")
        case "distribution.package.description.template":
            String(localized: "The package still uses the template’s description")
        case "distribution.package.author.template": String(localized: "The package still uses the template’s author")
        case "distribution.package.version.template":
            String(localized: "The package still uses the template’s initial version")
        case "distribution.package.id.local": String(localized: "The package uses a placeholder identifier")
        case "distribution.bundleID.local": String(localized: "The app uses a placeholder bundle identifier")
        case "distribution.icon.missing": String(localized: "The app has no icon")
        case versionPackaged: String(localized: "A build of this version exists")
        case "distribution.package.id.differs": String(localized: "The other target’s package is different")
        default: issue.message
        }
    }

    /// What to change; nil for a finding the app does not know, whose
    /// message is already its title.
    static func advice(for issue: ProjectDiagnostic) -> String? {
        switch issue.code {
        case "distribution.package.name.template":
            String(localized: "Give it the name people will see in their package manager.")
        case "distribution.package.description.template": String(localized: "Describe what the package does.")
        case "distribution.package.author.template": String(localized: "Add the author’s name.")
        case "distribution.package.version.template": String(localized: "Give the first release its own version.")
        case "distribution.package.id.local", "distribution.bundleID.local":
            String(localized: "Use a reverse-DNS identifier you own.")
        case "distribution.icon.missing": String(localized: "The Home Screen and package managers show a blank icon.")
        case versionPackaged:
            String(localized: "Publish or share that build as it is. Raise the version only to ship a change, so package managers offer it as an update.")
        case "distribution.package.id.differs": String(localized: "Both targets should ship the same package.")
        default: nil
        }
    }
}
