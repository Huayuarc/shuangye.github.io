@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAI
import Testing

/// A project kept the `local.apelin.` identifiers Apelin made up until
/// release preparation, after a debug package was installed, and its
/// package ID changed then. The moments a new project takes shape now say
/// so in their result: an automatic rename, and a Debug build while nothing
/// of the project is installed (apelin_project_create's is the worker's,
/// `PlaceholderIdentifierBackendTests`).
@Suite("Placeholder identifiers")
struct PlaceholderIdentifierTests {
    private static let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>CFBundleIdentifier</key>
    \t<string>local.apelin.banana</string>
    </dict>
    </plist>
    """

    /// A project of `kind` packaged as `packageID`, whose one product is an
    /// app for an app and a dylib otherwise.
    private static func manifest(kind: String = "tweak", packageID: String = "local.apelin.banana") -> String {
        let type = kind == "app" ? "app" : "dylib"
        return #"{"schemaVersion":1,"projectID":"x","kind":"\#(kind)","products":[{"id":"main","type":"\#(type)","name":"Banana","sources":["Sources/*.m"],"infoPlist":"Resources/Info.plist"}],"package":{"id":"\#(packageID)","version":"0.0.1"}}"#
    }

    private static let installed = ListedInstallation(
        installationID: "11111111-1111-4111-8111-111111111111",
        packageID: "local.apelin.banana",
        version: "0.0.1",
        installedAt: Date(timeIntervalSince1970: 1_790_000_000),
        removable: true,
    )

    /// A tool's result as the model reads it, decoded.
    private func run(
        _ harness: DigestApprovalTests.Harness,
        _ tool: AgentToolName,
        _ arguments: JSONValue = [:],
    ) async throws -> [String: Any] {
        let (result, _) = try await harness.run(tool, arguments)
        let text = result.content.compactMap {
            if case let .text(text) = $0 {
                text.text
            } else {
                nil
            }
        }.joined()
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test
    func `an automatic rename names the placeholders and what to agree with the user`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest(kind: "app"))
        try harness.home.write("Resources/Info.plist", Self.infoPlist)

        let renamed = try await run(harness, .projectRename, ["display_name": "Lock Screen Clock", "automatic": true])
        let hint = try #require(renamed["identifierHint"] as? String)
        #expect(hint.hasPrefix("This project's package ID local.apelin.banana and app bundle ID local.apelin.banana are placeholders Apelin made up: ask the user for permanent ones before the first install and keep them the same for debug and release builds"))
        #expect(hint.contains("file_grep for local.apelin."))
        #expect(hint.contains("a new identifier makes another package: agree a migration with the user first, as the apelin-packaging-and-install skill says."))

        try harness.home.write("apelin-project.json", Self.manifest())
        let tweak = try await run(harness, .projectRename, ["display_name": "Clock", "automatic": true])
        #expect((tweak["identifierHint"] as? String)?.hasPrefix("This project's package ID local.apelin.banana is a placeholder Apelin made up: ask the user for a permanent one before the first install and keep it the same") == true)
    }

    @Test
    func `a rename the user asked for, or of a project with real identifiers, carries no note`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest())
        let asked = try await run(harness, .projectRename, ["display_name": "Clock"])
        #expect(asked["identifierHint"] == nil, "only the name a new project's goal gives it")

        try harness.home.write("apelin-project.json", Self.manifest(kind: "app", packageID: "com.example.clock"))
        try harness.home.write("Resources/Info.plist", Self.infoPlist.replacingOccurrences(of: "local.apelin.banana", with: "com.example.clock"))
        let real = try await run(harness, .projectRename, ["display_name": "Clock", "automatic": true])
        #expect(real["identifierHint"] == nil)

        // An app whose bundle ID alone is still the placeholder names it alone.
        try harness.home.write("Resources/Info.plist", Self.infoPlist)
        let bundle = try await run(harness, .projectRename, ["display_name": "Clock", "automatic": true])
        #expect((bundle["identifierHint"] as? String)?.hasPrefix("This project's app bundle ID local.apelin.banana is a placeholder") == true)
    }

    @Test
    func `a Debug build says to ask before installing while nothing of the project is installed`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest())
        await harness.backend.setInstallations([])

        let built = try await run(harness, .projectBuild)
        #expect(built["succeeded"] as? Bool == true)
        let hint = try #require(built["identifierHint"] as? String)
        #expect(hint == "This project's package ID local.apelin.banana is a placeholder Apelin made up, and nothing it built is installed now. Before installing, ask the user for a permanent one or whether to keep it, the same for debug and release builds: changed after an install, an identifier makes another package (apelin-packaging-and-install skill).")
        #expect(await harness.backend.installationQueries == [InstallationListToolRequest(projectID: harness.home.project.id)])

        let release = try await run(harness, .projectBuild, ["configuration": "release"])
        #expect(release["identifierHint"] == nil, "a release build has the distribution check's warnings")
    }

    @Test
    func `a build carries no note once the project's package is installed, when that does not read, or with real identifiers`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest())

        let unread = try await run(harness, .projectBuild)
        #expect(unread["identifierHint"] == nil, "nothing says the first install is still ahead")

        var installed = Self.installed
        installed.projectID = harness.home.project.id
        await harness.backend.setInstallations([installed])
        let after = try await run(harness, .projectBuild)
        #expect(after["identifierHint"] == nil, "an installed package's identity is the user's to change")

        await harness.backend.setInstallations([])
        try harness.home.write("apelin-project.json", Self.manifest(packageID: "com.example.clock"))
        let queries = await harness.backend.installationQueries.count
        let real = try await run(harness, .projectBuild)
        #expect(real["identifierHint"] == nil)
        #expect(await harness.backend.installationQueries.count == queries, "nothing to ask the host about")

        // A placeholder spelled as no package ID is not quoted.
        try harness.home.write("apelin-project.json", Self.manifest(packageID: "local.apelin.Banana; rm -rf ~"))
        let odd = try await run(harness, .projectBuild)
        #expect(odd["identifierHint"] == nil)
    }

    @Test
    func `the prompt and the install skill settle identifiers before the first install and change one only by agreement`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [], mcpServers: [])
        let working = try #require(prompt.range(of: "# Working")?.upperBound)
        let device = try #require(prompt.range(of: "# This device")?.lowerBound)
        let section = prompt[working ..< device]
        #expect(section.contains("A new project's package ID and an app's bundle ID start as local.apelin.… placeholders: ask the user for permanent ones before the project's first install, and keep them the same for debug and release builds."))
        #expect(section.contains("Never change one on your own once its package is installed: a new identifier is another package, so agree a migration with the user first"))

        let skill = BuiltInSkills.packagingAndInstall.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(skill.contains("## Package identity"))
        #expect(skill.contains("Debug and release builds carry the same identifiers"))
        #expect(skill.contains("The new ID is another package, and the old one stays installed until it is removed."))
        #expect(skill.contains("remove the old installation with `apelin_package_remove` (in Strict mode it asks), then install the new package, and only with the user's agreement"))
        #expect(skill.contains("Nothing follows the identity"))
        #expect(AgentToolName.projectCreate.summary.contains("packageID and bundleID when the user has chosen permanent identifiers"))
    }

    @Test
    func `a workspace's build, which has no description, carries no note`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .relaxed)
        defer { harness.home.remove() }
        try harness.home.write(
            "apelin-project.json",
            #"{"schemaVersion":1,"projectID":"x","kind":"workspace","buildSystem":"external","external":{"script":"apelin/build.sh"},"package":{"id":"local.apelin.banana"}}"#,
        )
        await harness.backend.setInstallations([])
        let built = try await run(harness, .projectBuild)
        #expect(built["succeeded"] as? Bool == true)
        #expect(built["identifierHint"] == nil)
    }
}
