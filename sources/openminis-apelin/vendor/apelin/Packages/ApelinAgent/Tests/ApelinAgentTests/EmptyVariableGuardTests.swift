@testable import ApelinAgent
import Foundation
import Testing

/// An empty variable in a removed path removes from `/`, which on roothide
/// is the bootstrap's root, and a maintainer script runs as root. The
/// prompt and the skills that hand out scripts say to stop first, and the
/// workspace build script's first lines do.
struct EmptyVariableGuardTests {
    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test
    func `every chat is told to stop on an empty variable before it removes anything`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        for project in [home.project, general] {
            let prompt = SystemPrompt.make(project: project, projectRoot: home.projectURL.path,
                                           skills: [], mcpServers: [])
            let working = try #require(prompt.range(of: "# Working")?.upperBound)
            let device = try #require(prompt.range(of: "# This device")?.lowerBound)
            let section = prompt[working ..< device]
            #expect(section.contains("removes, moves or overwrites a path with a variable in it stops first when the variable is empty or unset: spell it `${name:?}`"))
            #expect(section.contains("which on roothide is the bootstrap's root, and a maintainer script runs as root"))
        }
        #expect(Self.words(BuiltInSkills.packagingAndInstall.body).contains("spells it `${name:?}`, so the script stops when the variable is empty"))
        #expect(Self.words(BuiltInSkills.bootstrapPaths.body).contains("Each is checked before it is used (`${APELIN_PACKAGE_DIR:?}`)"))
    }

    /// The skill's script, its block as the model reads it, with a line
    /// after that would show it went on.
    private func firstLines() throws -> String {
        let body = BuiltInSkills.externalBuild.body
        let section = try #require(body.range(of: "## Its first lines")?.upperBound)
        let open = try #require(body.range(of: "```sh\n", range: section ..< body.endIndex)?.upperBound)
        let close = try #require(body.range(of: "```", range: open ..< body.endIndex)?.lowerBound)
        return String(body[open ..< close])
    }

    private func run(_ script: String, environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(.timeLimit(.minutes(1)))
    func `the workspace build script's first lines stop before anything when Apelin set nothing`() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("apelin-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let script = try firstLines() + "echo \"stage=$stage\"\n"

        // A shell_run of the script: none of Apelin's variables.
        let bare = try run(script, environment: ["PATH": "/usr/bin:/bin"])
        #expect(bare.status != 0)
        #expect(bare.output.contains("run this through apelin_project_build"))
        #expect(!bare.output.contains("stage="))

        // One of them empty is as good as missing.
        var built: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "APELIN_PACKAGE_DIR": temporary.appendingPathComponent("package").path,
            "APELIN_PROJECT_ROOT": temporary.path,
            "APELIN_BOOTSTRAP": "roothide",
            "APELIN_ARCHITECTURE": "iphoneos-arm64e",
            "APELIN_BUILD_ID": "build",
            "APELIN_PREFIX": "",
            "TMPDIR": temporary.path + "/",
        ]
        var emptied = built
        emptied["APELIN_PROJECT_ROOT"] = ""
        let empty = try run(script, environment: emptied)
        #expect(empty.status != 0)
        #expect(!empty.output.contains("stage="))

        // As apelin_project_build runs it: an empty prefix is roothide's,
        // and the stage goes when the script ends.
        let ran = try run(script, environment: built)
        #expect(ran.status == 0, "\(ran.output)")
        let stage = try #require(ran.output.split(separator: "\n").first { $0.hasPrefix("stage=") }?.dropFirst("stage=".count))
        #expect(stage.hasPrefix(temporary.path + "/stage."))
        #expect(!FileManager.default.fileExists(atPath: String(stage)))

        built.removeValue(forKey: "APELIN_PREFIX")
        let unset = try run(script, environment: built)
        #expect(unset.status != 0, "an unset prefix is not roothide's empty one")
    }
}
