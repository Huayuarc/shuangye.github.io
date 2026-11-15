@testable import ApelinAgent
import ApelinProtocol
import Foundation
import Testing

/// Settings ▸ Skills reads the catalogue a session reads: the built-ins,
/// the skills folder, and where in it each skill and problem sits.
struct SkillListingTests {
    @Test
    func `the listing names each skill's place in the folder, and each problem's`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let skills = home.dataRoot.skills
        func write(_ relative: String, _ text: String) throws {
            let url = skills.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("release-notes/SKILL.md", "---\nname: release-notes\ndescription: Write release notes.\n---\nSymptom first.")
        try write("release-notes/template.md", "# Template")
        try write("nested/lint/SKILL.md", "---\nname: lint\ndescription: Lint a project.\n---\nRun the linter.")
        try write("broken/SKILL.md", "---\nname: broken\n---\nNo description.")
        try write("clash/SKILL.md", "---\nname: apelin-tweak-development\ndescription: Shadows a built-in.\n---\nNo.")

        let listing = SkillCatalog.listing(userDirectory: skills)
        let builtIn = try #require(listing.skills.first { $0.name == "apelin-project-description" })
        #expect(builtIn.source == .builtIn && builtIn.location == nil && !builtIn.files.isEmpty)
        let notes = try #require(listing.skills.first { $0.name == "release-notes" })
        #expect(notes.source == .user && notes.location == "release-notes")
        #expect(notes.body == "Symptom first." && notes.files == ["template.md"])
        #expect(listing.skills.first { $0.name == "lint" }?.location == "nested/lint")
        #expect(!listing.skills.contains { $0.name == "broken" })
        #expect(listing.problems.contains { $0.location == "broken" && $0.message.contains("description") })
        #expect(listing.problems.contains { $0.location == "clash" && $0.message.contains("built-in") })
    }

    @Test
    func `a location is the folder of a SKILL.md, else the file, and nothing outside`() {
        let root = "/data/skills"
        #expect(SkillCatalog.location(of: "/data/skills/a/SKILL.md", in: root) == "a")
        #expect(SkillCatalog.location(of: "/data/skills/notes.md", in: root) == "notes.md")
        #expect(SkillCatalog.location(of: "/data/skills/SKILL.md", in: root) == nil)
        #expect(SkillCatalog.location(of: "/data/other/a/SKILL.md", in: root) == nil)
    }
}
