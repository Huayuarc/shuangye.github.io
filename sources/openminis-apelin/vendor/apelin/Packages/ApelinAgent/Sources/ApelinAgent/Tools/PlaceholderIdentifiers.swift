import Foundation

/// The identifiers `projectCreate` makes up for a project nobody gave them
/// to, `local.apelin.<the folder's slug>`, while the project still has
/// them: its package ID and its app's bundle ID. The distribution check
/// names them only when a release is prepared; in one project the package
/// ID was changed then, after a debug package was installed, and the user
/// met installer errors moving from one to the other. So the moments a new
/// project takes shape say so in their result, for the agent to ask the
/// user first: apelin_project_create, an automatic apelin_project_rename,
/// and a Debug build while nothing the project built is installed. A note,
/// never a refusal.
public enum PlaceholderIdentifiers {
    /// What `projectCreate` puts in front of an identifier nobody chose, as
    /// apelin-build's `DistributionCheck` reads it.
    static let prefix = "local.apelin."

    /// apelin_project_create's, for the project it made at `root`: the
    /// conversation that made it has no file tools there.
    public static func createHint(in root: ScopedRoot) -> String? {
        guard let named = named(in: root) else { return nil }
        return "Its \(named.subject) Apelin made up. Before its first install the user should choose \(named.permanent), kept the same for debug and release builds: ask here and pass \(named.them) on in the prompt of the conversation you open for it, or tell that conversation to ask."
    }

    /// An automatic apelin_project_rename's: the project has just taken
    /// the name its goal gave it.
    static func renameHint(in root: ScopedRoot) -> String? {
        guard let named = named(in: root) else { return nil }
        return "This project's \(named.subject) Apelin made up: ask the user for \(named.permanent) before the first install and keep \(named.them) the same for debug and release builds (file_grep for local.apelin. finds every file that spells one). Once a package of this project is installed, a new identifier makes another package: agree a migration with the user first, as the apelin-packaging-and-install skill says."
    }

    /// A Debug build's, while nothing the project built is installed.
    static func buildHint(in root: ScopedRoot) -> String? {
        guard let named = named(in: root) else { return nil }
        return "This project's \(named.subject) Apelin made up, and nothing it built is installed now. Before installing, ask the user for \(named.permanent) or whether to keep \(named.them), the same for debug and release builds: changed after an install, an identifier makes another package (apelin-packaging-and-install skill)."
    }

    /// Each placeholder the project still carries, as the notes name it:
    /// the package ID, then the app product's bundle ID. One that is not
    /// spelled as an identifier is left out, since the files are the
    /// project's, whatever they hold.
    static func found(in root: ScopedRoot) -> [String] {
        guard let manifest = ProjectBuildSystem.manifest(in: root) else { return [] }
        var found: [String] = []
        if let packageID = (manifest["package"] as? [String: Any])?["id"] as? String, packageID.hasPrefix(prefix),
           packageID.count <= 255, packageID.allSatisfy(packageIDCharacters.contains)
        {
            found.append("package ID \(packageID)")
        }
        if let bundleID = AppRelaunch.bundleID(manifest, in: root), bundleID.hasPrefix(prefix) {
            found.append("app bundle ID \(bundleID)")
        }
        return found
    }

    /// What a Debian package name is made of.
    private static let packageIDCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789+-.")

    /// The placeholders as a sentence's subject, and the words for them later.
    private static func named(in root: ScopedRoot) -> (subject: String, permanent: String, them: String)? {
        let found = found(in: root)
        guard !found.isEmpty else { return nil }
        let single = found.count == 1
        return (
            subject: "\(found.joined(separator: " and ")) \(single ? "is a placeholder" : "are placeholders")",
            permanent: single ? "a permanent one" : "permanent ones",
            them: single ? "it" : "them",
        )
    }
}
