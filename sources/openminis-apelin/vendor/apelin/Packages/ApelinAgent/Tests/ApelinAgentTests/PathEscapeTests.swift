@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

@Suite("Project root containment")
struct PathEscapeTests {
    let home: TemporaryHome
    let tools: ProjectFileTools
    let outside: URL

    init() throws {
        home = try TemporaryHome()
        try home.write("Sources/Tweak.m", "int a = 1;\n")
        outside = home.home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret\n".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        tools = try ProjectFileTools(root: ScopedRoot(home.projectURL))
    }

    private func link(_ name: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: home.projectURL.appendingPathComponent(name).path, withDestinationPath: destination)
    }

    private func refused(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch let error as PathPolicyError {
            switch error {
            case .outsideRoot, .symlinkRefused, .embeddedNUL: return true
            default: return false
            }
        } catch { return false }
    }

    @Test
    func `dot-dot, absolute and home paths are refused`() {
        defer { home.remove() }
        #expect(refused { _ = try tools.readFile(["path": "../../../../outside/secret.txt"]) })
        #expect(refused { _ = try tools.readFile(["path": .string(outside.appendingPathComponent("secret.txt").path)]) })
        #expect(refused { _ = try tools.readFile(["path": "~/outside/secret.txt"]) })
        #expect(refused { _ = try tools.writeFile(["path": "../escape.txt", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "Sources/../../escape.txt", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "new/../../escape.txt", "content": "x"]) })
        #expect(!FileManager.default.fileExists(atPath: home.dataRoot.projects.appendingPathComponent("escape.txt").path))
    }

    @Test
    func `an embedded NUL is refused first`() {
        defer { home.remove() }
        #expect(refused { _ = try tools.readFile(["path": "Sources/Tweak.m\0../../x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "a\0b", "content": "x"]) })
    }

    @Test
    func `links that leave the project are not followed`() throws {
        defer { home.remove() }
        try link("outdir", to: outside.path)
        try link("secret-link.txt", to: outside.appendingPathComponent("secret.txt").path)
        try link("dangling.txt", to: outside.appendingPathComponent("not-yet.txt").path)

        #expect(refused { _ = try tools.readFile(["path": "outdir/secret.txt"]) })
        #expect(refused { _ = try tools.readFile(["path": "secret-link.txt"]) })
        #expect(refused { _ = try tools.writeFile(["path": "outdir/new.txt", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "outdir/deep/new.txt", "content": "x"]) })
        #expect(refused { _ = try tools.writeFile(["path": "secret-link.txt", "content": "pwned"]) })
        #expect(refused { _ = try tools.patchFile(["path": "secret-link.txt", "old_text": "secret", "new_text": "pwned"]) })
        #expect(refused { _ = try tools.writeFile(["path": "dangling.txt", "content": "x"]) })
        #expect(refused { _ = try tools.list(["path": "outdir"]) })
        #expect(refused { _ = try tools.grep(["pattern": "secret", "path": "outdir"]) })

        #expect(try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8) == "secret\n")
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("not-yet.txt").path))
        // grep over the root does not descend into the link either.
        #expect(try tools.grep(["pattern": "secret"]) == "(no matches)")
    }

    @Test
    func `a link that stays inside may be read, but is not written through`() throws {
        defer { home.remove() }
        try link("alias.m", to: home.projectURL.appendingPathComponent("Sources/Tweak.m").path)
        #expect(try tools.readFile(["path": "alias.m"]).contains("int a = 1;"))
        #expect(refused { _ = try tools.writeFile(["path": "alias.m", "content": "x"]) })
    }

    @Test
    func `the project root itself cannot be a link elsewhere`() throws {
        defer { home.remove() }
        let other = home.dataRoot.projects.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: outside.path)
        let projects = try ScopedRoot(home.dataRoot.projects)
        let linkedRoot = try ScopedRoot(other)
        #expect(!projects.contains(linkedRoot.path))
    }

    @Test
    func `write, create and patch work inside`() throws {
        defer { home.remove() }
        _ = try tools.createFile(["path": "Sources/New/Hook.m", "content": "// new\n"])
        #expect(try home.read("Sources/New/Hook.m") == "// new\n")
        #expect(throws: PathPolicyError.self) { _ = try tools.createFile(["path": "Sources/New/Hook.m", "content": "again"]) }

        _ = try tools.writeFile(["path": "Sources/Tweak.m", "content": "int a = 2;\nint b = 3;\n"])
        let result = try tools.patchFile(["path": "Sources/Tweak.m", "old_text": "int b = 3;", "new_text": "int b = 4;"])
        #expect(result.contains("-int b = 3;"))
        #expect(result.contains("+int b = 4;"))
        #expect(try home.read("Sources/Tweak.m") == "int a = 2;\nint b = 4;\n")

        // Ambiguous patches are refused rather than guessed.
        _ = try tools.writeFile(["path": "twice.txt", "content": "x x"])
        #expect(throws: ToolArgumentError.self) { _ = try tools.patchFile(["path": "twice.txt", "old_text": "x", "new_text": "y"]) }
        _ = try tools.patchFile(["path": "twice.txt", "old_text": "x", "new_text": "y", "replace_all": true])
        #expect(try home.read("twice.txt") == "y y")

        #expect(try tools.find(["pattern": "*.m"]).contains("Sources/New/Hook.m"))
        #expect(try tools.grep(["pattern": "int b"]).contains("Sources/Tweak.m:2:"))
        #expect(try tools.list(["depth": 2]).contains("Sources/"))
    }

    @Test
    func `project names are single safe components`() {
        for bad in ["", ".", "..", ".hidden", "a/b", "a\0b"] {
            #expect(throws: PathPolicyError.self) { try ProjectName(bad) }
        }
        #expect(throws: Never.self) { try ProjectName("My Tweak") }
    }
}
