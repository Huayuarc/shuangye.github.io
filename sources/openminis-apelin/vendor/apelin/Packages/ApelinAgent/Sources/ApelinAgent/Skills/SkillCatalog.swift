import Foundation
import KWWKAgent

/// A skill as the session uses it.
public struct SkillDocument: Sendable, Hashable {
    public var name: String
    public var description: String
    public var body: String
    /// True for skills read from the user's folder.
    public var isUserSkill: Bool
    /// The folder a user skill's `SKILL.md` sits in, whose other files
    /// `apelin_skill_read` may read; nil for a built-in or a root-level `.md`.
    public var directory: String?
    /// A built-in skill's files, by name, which `apelin_skill_read` serves as a
    /// user skill's folder is served.
    public var files: [String: String]
    /// A user skill's place in the skills folder, relative to it: what
    /// removing the skill takes away (`SkillCatalog.location`).
    public var location: String?

    public init(
        name: String,
        description: String,
        body: String,
        isUserSkill: Bool = false,
        directory: String? = nil,
        files: [String: String] = [:],
        location: String? = nil,
    ) {
        self.name = name
        self.description = description
        self.body = body
        self.isUserSkill = isUserSkill
        self.directory = directory
        self.files = files
        self.location = location
    }
}

/// Something in the skills folder that is not offered as it stands, or is
/// offered with a warning: kwwk's diagnostic, or a built-in's name taken.
public struct SkillProblem: Sendable, Hashable, CustomStringConvertible {
    public var path: String
    /// What removing it takes away, relative to the skills folder.
    public var location: String?
    public var message: String

    public var description: String {
        "\(path): \(message)"
    }
}

/// The built-in skills plus the user's, from
/// `~/Documents/wiki.qaq.apelin/skills` (kwwk's skill format: a folder per
/// skill with a `SKILL.md`, or a root-level `.md`, with `name` and
/// `description` frontmatter).
///
/// The system prompt lists only each skill's name and description, as pi's
/// `<available_skills>` does; the body is read on demand with `apelin_skill_read`,
/// since the file tools cannot read outside the project.
public enum SkillCatalog {
    public static func load(userDirectory: URL) -> (skills: [SkillDocument], diagnostics: [SkillProblem]) {
        var skills = BuiltInSkills.all
        var names = Set(skills.map(\.name))
        let loaded = Skills.load(directories: [userDirectory.path], useIndex: false)
        let userRoot = userDirectory.standardizedFileURL.path
        var diagnostics = loaded.diagnostics.map {
            SkillProblem(path: $0.path, location: location(of: $0.path, in: userRoot), message: $0.message)
        }
        for skill in loaded.skills where !skill.disableModelInvocation {
            // A built-in name is not overridden by a file.
            guard names.insert(skill.name).inserted else {
                diagnostics.append(SkillProblem(
                    path: skill.path,
                    location: location(of: skill.path, in: userRoot),
                    message: "“\(skill.name)” is the name of a built-in skill. Rename this skill to use it.",
                ))
                continue
            }
            let file = URL(fileURLWithPath: skill.path).standardizedFileURL
            let folder = file.deletingLastPathComponent().path
            skills.append(SkillDocument(
                name: skill.name,
                description: skill.description,
                body: skill.body,
                isUserSkill: true,
                directory: file.lastPathComponent == "SKILL.md" && folder != userRoot ? folder : nil,
                location: location(of: skill.path, in: userRoot),
            ))
        }
        return (skills, diagnostics)
    }

    /// A skill file's place in the skills folder `root`, as removing the
    /// skill takes it away: a `SKILL.md`'s folder, else the file itself;
    /// nil outside the folder, or for the folder itself.
    static func location(of path: String, in root: String) -> String? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let removed = file.lastPathComponent == "SKILL.md" ? file.deletingLastPathComponent() : file
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard removed.path.hasPrefix(prefix) else { return nil }
        return String(removed.path.dropFirst(prefix.count))
    }

    static func promptSection(_ skills: [SkillDocument]) -> String {
        guard !skills.isEmpty else { return "" }
        var lines = [
            "# Skills",
            "Skills hold detailed instructions for particular tasks. When a task matches a skill's description, call apelin_skill_read with its name before you start, and follow it.",
            "",
            "<available_skills>",
        ]
        for skill in skills {
            let source = skill.isUserSkill ? " source=\"user\"" : ""
            lines.append("<skill name=\"\(escape(skill.name))\"\(source)>\(escape(skill.description))</skill>")
        }
        lines.append("</available_skills>")
        return lines.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
