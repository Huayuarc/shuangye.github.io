import ApelinProtocol
import Foundation

public extension SkillCatalog {
    /// Settings ▸ Skills: the skills a session is offered, read as a session
    /// reads them, each with the instructions and files `apelin_skill_read` would
    /// serve, and what in the skills folder is not offered as it stands.
    static func listing(userDirectory: URL) -> AgentSkillListResponse {
        let catalog = load(userDirectory: userDirectory)
        return AgentSkillListResponse(
            skills: catalog.skills.map { skill in
                AgentSkill(
                    name: skill.name,
                    description: skill.description,
                    source: skill.isUserSkill ? .user : .builtIn,
                    body: SkillReader.bounded(Data(skill.body.utf8), SkillReader.maxBodyBytes),
                    files: skill.files.keys.sorted() + (skill.directory.map(SkillReader.files(in:)) ?? []),
                    location: skill.location,
                )
            },
            problems: catalog.diagnostics.map { AgentSkillProblem(location: $0.location, message: $0.message) },
        )
    }
}
