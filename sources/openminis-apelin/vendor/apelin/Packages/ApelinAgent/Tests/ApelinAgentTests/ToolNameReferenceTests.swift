@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAI
import Testing

/// What the model reads names the tools it has: no prompt, tool
/// description, skill or message of the agent's own spells a name an
/// earlier release gave a tool, which the model would call and find gone.
@Suite("Tool names in what the model reads")
struct ToolNameReferenceTests {
    /// Every earlier name with an underscore, which no other word spells.
    private static let compoundLegacyNames = Set(AgentToolName.legacyNames.keys.filter { $0.contains("_") })
    /// The one-word earlier names (`build`, `list` …): ordinary words too,
    /// so only a backticked one counts as a tool's.
    private static let wordLegacyNames = Set(AgentToolName.legacyNames.keys.filter { !$0.contains("_") })

    private static func legacyNames(in text: String) -> [String] {
        let tokens = text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
        let words = wordLegacyNames.filter { text.contains("`\($0)`") }
        return Array(Set(tokens).intersection(compoundLegacyNames)) + words.sorted()
    }

    private static func prompts(_ home: TemporaryHome) throws -> [String] {
        let id = UUID().uuidString
        let temporary = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        let server = try MCPServerConfiguration(name: "docs", url: #require(URL(string: "https://example.com/mcp")))
        let environment = try EnvironmentPrompt.section(EnvironmentPrompt.inputs(
            AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            root: ScopedRoot(home.projectURL),
            device: .current,
        ))
        var prompts: [String] = []
        for (project, buildSystem) in [(home.project, ProjectBuildSystem.apelin), (home.project, .external), (temporary, .apelin)] {
            prompts.append(SystemPrompt.make(
                project: project,
                projectRoot: home.projectURL.path,
                skills: BuiltInSkills.all,
                mcpServers: [server],
                buildSystem: buildSystem,
                memory: MemoryTools.prompt(nil),
                environment: environment,
            ))
        }
        // and the block before each message, in every mode
        for mode in [ApprovalMode.relaxed, .confirm, .full] {
            prompts.append(SystemState.make(SystemState.facts(.device, mode: mode)))
        }
        // The note that old names may be met is the one place they are named.
        return prompts.map { $0.replacingOccurrences(of: SystemPrompt.renamedToolsNote, with: "") }
    }

    @Test
    func `the system prompt names only today's tools`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        for prompt in try Self.prompts(home) {
            #expect(Self.legacyNames(in: prompt).isEmpty, "\(Self.legacyNames(in: prompt))")
        }
    }

    @Test
    func `every tool's description and parameters name only today's tools`() {
        for tool in AgentToolName.allCases {
            let text = tool.summary + "\n" + ToolReason.adding(to: tool.parameters).canonicalJSON
            #expect(Self.legacyNames(in: text).isEmpty, "\(tool.rawValue): \(Self.legacyNames(in: text))")
        }
    }

    @Test
    func `every built-in skill names only today's tools`() {
        for skill in BuiltInSkills.all {
            var text = ([skill.description, skill.body] + skill.files.values).joined(separator: "\n")
            if skill.name == "apelin-project-description" {
                // `build` there is the member of apelin-project.json.
                text = text.replacingOccurrences(of: "`build`", with: "")
            }
            #expect(Self.legacyNames(in: text).isEmpty, "\(skill.name): \(Self.legacyNames(in: text))")
        }
    }

    /// The agent's sources, messages and comments alike: an error the model
    /// reads is written there too.
    @Test
    func `no source of the agent spells an earlier name`() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = package.appendingPathComponent("Sources", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
                .replacingOccurrences(of: SystemPrompt.renamedToolsNote, with: "")
            let tokens = Set(text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
            let found = tokens.intersection(Self.compoundLegacyNames)
            #expect(found.isEmpty, "\(file.lastPathComponent): \(found.sorted())")
            checked += 1
        }
        #expect(checked > 50, "the sources were found")
    }
}
