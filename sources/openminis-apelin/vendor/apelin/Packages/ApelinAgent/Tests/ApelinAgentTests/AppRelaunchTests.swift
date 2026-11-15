@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

/// On a device, an app installed again went on running its previous build
/// in the foreground, and the skill's `icli app kill <bundle id>` was
/// refused until the agent found `--force`.
@Suite("Restarting an installed app")
struct AppRelaunchTests {
    private static let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>CFBundleIdentifier</key>
    \t<string>local.apelin.demo</string>
    </dict>
    </plist>
    """

    /// A manifest of `kind` whose one product is an app for an app and a
    /// dylib otherwise, with an Info.plist either way.
    private static func manifest(kind: String) -> String {
        let type = kind == "app" ? "app" : "dylib"
        return #"{"schemaVersion":1,"projectID":"x","kind":"\#(kind)","products":[{"id":"main","type":"\#(type)","name":"Demo","sources":["Sources/*.m"],"infoPlist":"Resources/Info.plist"}]}"#
    }

    private static let arguments: JSONValue = ["artifact_id": "artifact-1", "artifact_digest": "deb-digest-1"]

    /// apelin_package_install's result, as the model reads it.
    private func install(_ harness: DigestApprovalTests.Harness) async throws -> [String: Any] {
        let (result, asked) = try await harness.run(.packageInstall, Self.arguments)
        #expect(asked.isEmpty, "a template package installs without asking")
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
    func `an app's install says a running copy keeps the previous build and how to restart it`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest(kind: "app"))
        try harness.home.write("Resources/Info.plist", Self.infoPlist)

        let result = try await install(harness)
        #expect(result["succeeded"] as? Bool == true)
        let hint = try #require(result["relaunchHint"] as? String)
        #expect(hint.contains("If local.apelin.demo is running, it still runs the previous build."))
        #expect(hint.contains("icli app kill --force local.apelin.demo, then icli app launch local.apelin.demo"))
        #expect(hint.contains("shell_run as mobile"))
    }

    @Test
    func `an app whose Info.plist does not read inside the project names the app's bundle id`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest(kind: "app"))

        var result = try await install(harness)
        var hint = try #require(result["relaunchHint"] as? String)
        #expect(hint.contains("icli app kill --force <bundle id>, then icli app launch <bundle id>"))
        #expect(hint.contains("CFBundleIdentifier"))

        // A link to a plist outside the project is not read through.
        let outside = harness.home.home.appendingPathComponent("Info.plist")
        try Self.infoPlist.write(to: outside, atomically: true, encoding: .utf8)
        let resources = harness.home.projectURL.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("Info.plist"), withDestinationURL: outside)
        result = try await install(harness)
        hint = try #require(result["relaunchHint"] as? String)
        #expect(!hint.contains("local.apelin.demo"))

        // Nor is an identifier that is not spelled as one.
        try FileManager.default.removeItem(at: resources.appendingPathComponent("Info.plist"))
        try harness.home.write("Resources/Info.plist", Self.infoPlist.replacingOccurrences(of: "local.apelin.demo", with: "demo; rm -rf ~"))
        result = try await install(harness)
        hint = try #require(result["relaunchHint"] as? String)
        #expect(hint.contains("<bundle id>") && !hint.contains("rm -rf"))
    }

    @Test
    func `a tweak's install and a failed install carry no hint`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest(kind: "tweak"))
        try harness.home.write("Resources/Info.plist", Self.infoPlist)
        let tweak = try await install(harness)
        #expect(tweak["succeeded"] as? Bool == true)
        #expect(tweak["relaunchHint"] == nil)

        try harness.home.write("apelin-project.json", Self.manifest(kind: "app"))
        await harness.backend.setInstallSucceeds(false)
        let failed = try await install(harness)
        #expect(failed["succeeded"] as? Bool == false)
        #expect(failed["relaunchHint"] == nil)
    }

    @Test
    func `the skills restart an app with icli's kill --force, then launch`() throws {
        let icli = try #require(BuiltInSkills.all.first { $0.name == "apelin-icli" }).body
        #expect(icli.contains("`app kill --force <bundle id>`"))
        #expect(!icli.contains("`app kill <"), "icli refuses a kill without --force")
        #expect(icli.contains("`app launch <bundle id>`"))

        let install = try #require(BuiltInSkills.all.first { $0.name == "apelin-packaging-and-install" }).body
        #expect(install.contains(#"{"argv": ["icli", "app", "kill", "--force", "<bundle id>"]}"#))
        #expect(install.contains(#"{"argv": ["icli", "app", "launch", "<bundle id>"]}"#))
        #expect(install.contains("`relaunchHint`"))
        #expect(install.contains("never with `root: true`"))
    }
}
