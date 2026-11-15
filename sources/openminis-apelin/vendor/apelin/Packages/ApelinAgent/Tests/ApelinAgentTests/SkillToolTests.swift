@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// apelin_skill_list, apelin_skill_save and apelin_skill_remove: the user's
/// skills folder, as Settings ▸ Skills writes it, each change asked about
/// in Strict mode with the whole skill on the card, never for the session.
@Suite("Skill tools")
struct SkillToolTests {
    private static let skill: JSONValue = [
        "name": "release-notes",
        "description": "Use when writing a release's notes.",
        "instructions": "# Release notes\nSymptom first, one bullet per change.",
    ]

    private static func text(_ result: AgentToolResult) -> String {
        result.content.compactMap {
            if case let .text(content) = $0 {
                content.text
            } else {
                nil
            }
        }
        .joined()
    }

    private func skillFile(_ harness: DigestApprovalTests.Harness, _ name: String) -> String? {
        let url = harness.home.dataRoot.skills.appendingPathComponent(name).appendingPathComponent("SKILL.md")
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a saved skill asks with its whole text, lands as kwwk reads it and is listed`() async throws {
        let harness = try DigestApprovalTests.Harness(skills: true)
        defer { harness.home.remove() }
        let (saved, asked) = try await harness.run(.skillSave, Self.skill)
        #expect(asked.count == 1)
        guard case let .skillChange(change)? = asked.first?.detail else {
            Issue.record("the card names the skill change")
            return
        }
        #expect(change.action == "save" && change.name == "release-notes" && !change.replacing)
        #expect(change.text == "---\nname: release-notes\ndescription: Use when writing a release's notes.\n---\n\n# Release notes\nSymptom first, one bullet per change.\n")
        #expect(asked.first?.allowsSessionScope == false, "never granted for the session")
        #expect(skillFile(harness, "release-notes") == change.text)
        #expect(Self.text(saved).contains("\"location\" : \"release-notes\""))

        let catalog = SkillCatalog.load(userDirectory: harness.home.dataRoot.skills)
        #expect(catalog.diagnostics.isEmpty)
        #expect(catalog.skills.contains { $0.name == "release-notes" && $0.isUserSkill && $0.description == "Use when writing a release's notes." })
        let (listed, listAsked) = try await harness.run(.skillList, [:])
        #expect(listAsked.isEmpty, "listing is a read preset")
        #expect(Self.text(listed).contains("\"name\" : \"release-notes\"") && Self.text(listed).contains("\"source\" : \"builtIn\""))
    }

    @Test(.timeLimit(.minutes(1)))
    func `a declined save writes nothing, and Relaxed saves without asking`() async throws {
        let strict = try DigestApprovalTests.Harness(skills: true)
        defer { strict.home.remove() }
        await #expect(throws: ToolDeniedError.self) {
            _ = try await strict.run(.skillSave, Self.skill, answering: .deny(reason: nil))
        }
        #expect(skillFile(strict, "release-notes") == nil)

        let relaxed = try DigestApprovalTests.Harness(mode: .relaxed, skills: true)
        defer { relaxed.home.remove() }
        let (_, asked) = try await relaxed.run(.skillSave, Self.skill)
        #expect(asked.isEmpty)
        #expect(skillFile(relaxed, "release-notes") != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a skill there is replaced only when asked, and the card says so`() async throws {
        let harness = try DigestApprovalTests.Harness(skills: true)
        defer { harness.home.remove() }
        _ = try await harness.run(.skillSave, Self.skill)
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.skillSave, Self.skill) }
        var again = Self.skill
        if case var .object(fields) = again {
            fields["instructions"] = "Changed."
            fields["replace"] = true
            again = .object(fields)
        }
        let (_, asked) = try await harness.run(.skillSave, again)
        guard case let .skillChange(change)? = asked.first?.detail else {
            Issue.record("the card names the skill change")
            return
        }
        #expect(change.replacing)
        #expect(asked.first?.reason.contains("replacing the one of that name") == true)
        #expect(skillFile(harness, "release-notes")?.hasSuffix("\n\nChanged.\n") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a name, description or text kwwk would not take is refused before asking`() async throws {
        let harness = try DigestApprovalTests.Harness(skills: true)
        defer { harness.home.remove() }
        func refused(_ change: (inout [String: JSONValue]) -> Void) async -> Bool {
            guard case var .object(fields) = Self.skill else { return false }
            change(&fields)
            do {
                _ = try await harness.run(.skillSave, .object(fields))
                return false
            } catch {
                return true
            }
        }
        #expect(await refused { $0["name"] = "Release Notes" })
        #expect(await refused { $0["name"] = "-notes" })
        #expect(await refused { $0["name"] = "release--notes" })
        #expect(await refused { $0["name"] = .string(String(repeating: "a", count: 65)) })
        #expect(await refused { $0["name"] = "../escape" })
        #expect(await refused { $0["name"] = .string(BuiltInSkills.all[0].name) }, "a built-in's name")
        #expect(await refused { $0["description"] = "Two\nlines" })
        #expect(await refused { $0["description"] = .string(String(repeating: "d", count: 1025)) })
        #expect(await refused { $0["instructions"] = "  " })
        #expect(await harness.events.events.isEmpty, "none of them reached the user")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: harness.home.dataRoot.skills.path)) ?? []).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a top-level skill file of that name, or a link in its place, is never written over`() async throws {
        let harness = try DigestApprovalTests.Harness(skills: true)
        defer { harness.home.remove() }
        let skills = harness.home.dataRoot.skills
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try Data("---\nname: release-notes\ndescription: Old.\n---\nOld.\n".utf8).write(to: skills.appendingPathComponent("release-notes.md"))
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.skillSave, Self.skill) }
        try FileManager.default.removeItem(at: skills.appendingPathComponent("release-notes.md"))

        let outside = harness.home.home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("release-notes"), withDestinationURL: outside)
        var replacing = Self.skill
        if case var .object(fields) = replacing {
            fields["replace"] = true
            replacing = .object(fields)
        }
        _ = try await harness.run(.skillSave, replacing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "nothing went through the link")
        let attributes = try FileManager.default.attributesOfItem(atPath: skills.appendingPathComponent("release-notes").path)
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory, "the link itself was replaced")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a user skill is removed by name after asking, a built-in never`() async throws {
        let harness = try DigestApprovalTests.Harness(skills: true)
        defer { harness.home.remove() }
        _ = try await harness.run(.skillSave, Self.skill)
        await #expect(throws: ToolArgumentError.self) {
            _ = try await harness.run(.skillRemove, ["name": .string(BuiltInSkills.all[0].name)])
        }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.skillRemove, ["name": "missing"]) }
        let (_, asked) = try await harness.run(.skillRemove, ["name": "release-notes"])
        guard case let .skillChange(change)? = asked.first?.detail else {
            Issue.record("the card names the skill change")
            return
        }
        #expect(change.action == "remove" && change.location == "release-notes" && change.text == nil)
        #expect(asked.first?.allowsSessionScope == false)
        #expect(skillFile(harness, "release-notes") == nil)
    }

    @Test
    func `the skill tools are offered in every chat and gated as the plan says`() {
        #expect(AgentToolName.skillList.risk == .readOnly && ApprovalPresets.default.readTools.contains(.skillList))
        for tool in [AgentToolName.skillSave, .skillRemove] {
            #expect(tool.risk == .system && !tool.isProjectOnly)
            #expect(!ToolRunner.allowsSessionScope(.local(tool), detail: .none))
        }
    }
}
