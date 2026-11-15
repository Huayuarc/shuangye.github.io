import Foundation

/// Where a skill comes from: built into Apelin, or the skills folder,
/// `~/Documents/wiki.qaq.apelin/skills`.
public enum AgentSkillSource: String, Codable, Sendable {
    case builtIn
    case user
}

/// A skill every chat is offered, as Settings ▸ Skills lists it.
public struct AgentSkill: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var source: AgentSkillSource
    /// The instructions, cut where `apelin_skill_read` cuts them.
    public var body: String
    /// The other files `apelin_skill_read` serves for it, relative to its folder.
    public var files: [String]
    /// A user skill's place in the skills folder, relative to it: its
    /// folder, or its file for a `.md` at the top. Absent for a built-in.
    public var location: String?

    public init(
        name: String,
        description: String,
        source: AgentSkillSource,
        body: String,
        files: [String] = [],
        location: String? = nil,
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.body = body
        self.files = files
        self.location = location
    }
}

/// Something in the skills folder that is not offered as it stands, or is
/// offered with a warning.
public struct AgentSkillProblem: Codable, Sendable, Equatable {
    /// What removing it takes away, relative to the skills folder, as
    /// `AgentSkill.location`; absent when that cannot be told.
    public var location: String?
    public var message: String

    public init(location: String?, message: String) {
        self.location = location
        self.message = message
    }
}

/// The skills the agent's sessions are offered, read the way a session
/// reads them. The app's alone.
public struct AgentSkillListRequest: OperationRequest {
    public typealias Response = AgentSkillListResponse
    public static let operation = AppOperation.agentSkillList
    public init() {}
}

public struct AgentSkillListResponse: Codable, Sendable, Equatable {
    public var skills: [AgentSkill]
    public var problems: [AgentSkillProblem]

    public init(skills: [AgentSkill] = [], problems: [AgentSkillProblem] = []) {
        self.skills = skills
        self.problems = problems
    }
}

public extension ApelinService {
    func agentSkillList() async throws -> AgentSkillListResponse {
        try await send(AgentSkillListRequest())
    }
}
