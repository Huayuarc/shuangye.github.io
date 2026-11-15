@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// The read tools reach Apelin's development extensions and the registered
/// SDKs by absolute path, in every mode and without asking; the write tools
/// never do, and nothing else outside the project opens.
@Suite("Read-only roots")
struct ReadOnlyRootTests {
    static let modes: [ApprovalMode] = [.confirm, .relaxed, .full]

    /// A home with an install root holding one extension's support header,
    /// a registered SDK's header, and a file outside every root.
    struct Fixture {
        let home: TemporaryHome
        let roots: ReadOnlyRoots
        let development: String
        let sdks: String
        let outside: URL

        init() throws {
            home = try TemporaryHome()
            try home.write("Sources/Pane.m", "#import <Preferences/PSListController.h>\n")
            let installRoot = home.home.appendingPathComponent("jb").path
            roots = ReadOnlyRoots(installRoot: installRoot, dataRoot: home.dataRoot)
            development = installRoot + "/usr/share/apelin/development"
            sdks = home.dataRoot.url.appendingPathComponent("SDKs").path
            outside = home.home.appendingPathComponent("outside/secret.txt")
            try Self.write(development + "/x/support/include/Preferences/PSListController.h", "@interface PSSpecifier : NSObject\n- (void)setProperty:(id)property forKey:(NSString *)key;\n@end\n")
            try Self.write(sdks + "/iPhoneOS18.2-aaaaaaaa/usr/include/sys/param.h", "#define MAXPATHLEN 1024\n")
            try Self.write(outside.path, "secret\n")
        }

        static func write(_ path: String, _ content: String) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        var header: String {
            development + "/x/support/include/Preferences/PSListController.h"
        }

        var sdkHeader: String {
            sdks + "/iPhoneOS18.2-aaaaaaaa/usr/include/sys/param.h"
        }

        func runner(_ mode: ApprovalMode, gate: ApprovalGate) throws -> ToolRunner {
            try ToolRunner(
                sessionID: UUID().uuidString,
                project: home.project,
                root: ScopedRoot(home.projectURL),
                policy: ApprovalPolicy(mode: mode),
                backend: MockBackend(),
                digests: MockDigestLedger(),
                gate: gate,
                readOnlyRoots: roots,
            )
        }

        /// Runs one tool; every approval it would ask for is declined and
        /// counted, so a call that asks fails the test instead of waiting.
        func run(_ tool: AgentToolName, _ arguments: JSONValue, mode: ApprovalMode) async throws -> (text: String, asked: Int) {
            let events = EventCollector()
            let gate = ApprovalGate { await events.add($0) }
            let declining = Task {
                while !Task.isCancelled {
                    for request in await gate.pending {
                        try? await gate.resolve(request.id, decision: .deny(reason: "test"))
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            defer { declining.cancel() }
            let result = try await runner(mode, gate: gate).run(
                .local(tool),
                toolCallID: UUID().uuidString,
                arguments: arguments,
                cancellation: nil,
                mcp: nil,
            )
            let asked = await events.events.filter { event in
                if case .approvalRequested = event {
                    return true
                }
                return false
            }.count
            let text = result.content.compactMap {
                if case let .text(content) = $0 {
                    content.text
                } else {
                    nil
                }
            }.joined()
            return (text, asked)
        }

        /// The refusal a call ends with, or nil when it ran.
        func refusal(_ tool: AgentToolName, _ arguments: JSONValue, mode: ApprovalMode) async -> String? {
            do {
                _ = try await run(tool, arguments, mode: mode)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `file_read reads an extension's support header and an SDK's header by absolute path, without asking`() async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        for mode in Self.modes {
            let header = try await fixture.run(.fileRead, ["path": .string(fixture.header)], mode: mode)
            #expect(header.text.contains("setProperty:(id)property forKey:"), "\(mode)")
            #expect(header.asked == 0, "\(mode)")
            let sdk = try await fixture.run(.fileRead, ["path": .string(fixture.sdkHeader)], mode: mode)
            #expect(sdk.text.contains("MAXPATHLEN"), "\(mode)")
            #expect(sdk.asked == 0, "\(mode)")
        }
        // The realpath reaches it too: /var/folders is /private/var/folders.
        let real = try #require(realpath(fixture.header, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(try await fixture.run(.fileRead, ["path": .string(real)], mode: .confirm).text.contains("PSSpecifier"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `file_list, file_grep and file_find search them and name what they find by its whole path`() async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        for mode in Self.modes {
            let listed = try await fixture.run(.fileList, ["path": .string(fixture.development + "/x/support/include"), "depth": 2], mode: mode)
            #expect(listed.text == "Preferences/\n  PSListController.h", "\(mode)")
            #expect(listed.asked == 0, "\(mode)")
            let grep = try await fixture.run(.fileGrep, ["pattern": "setProperty", "path": .string(fixture.development)], mode: mode)
            #expect(grep.text == fixture.header + ":2: - (void)setProperty:(id)property forKey:(NSString *)key;", "\(mode)")
            #expect(grep.asked == 0, "\(mode)")
            let found = try await fixture.run(.fileFind, ["pattern": "*.h", "path": .string(fixture.sdks)], mode: mode)
            #expect(found.text == fixture.sdkHeader, "\(mode)")
            #expect(found.asked == 0, "\(mode)")
            // What a search names reads back as it is.
            #expect(try await fixture.run(.fileRead, ["path": .string(found.text)], mode: mode).text.contains("MAXPATHLEN"))
        }
        // The project's own results stay relative to it.
        #expect(try await fixture.run(.fileFind, ["pattern": "*.m"], mode: .confirm).text == "Sources/Pane.m")
    }

    @Test(.timeLimit(.minutes(1)))
    func `the write tools never write there, in any mode`() async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        let original = try String(contentsOfFile: fixture.header, encoding: .utf8)
        for mode in Self.modes {
            for (tool, arguments) in [
                (AgentToolName.fileWrite, ["path": JSONValue.string(fixture.header), "content": "x"] as JSONValue),
                (.fileEdit, ["path": .string(fixture.header), "old_text": "PSSpecifier", "new_text": "x"]),
                (.fileCreate, ["path": .string(fixture.development + "/x/support/include/New.h"), "content": "x"]),
                (.fileCreate, ["path": .string(fixture.sdks + "/iPhoneOS18.2-aaaaaaaa/usr/include/New.h"), "content": "x"]),
            ] {
                let refusal = await fixture.refusal(tool, arguments, mode: mode)
                #expect(refusal?.contains("is outside the project") == true, "\(tool.rawValue) \(mode): \(refusal ?? "ran")")
            }
        }
        #expect(try String(contentsOfFile: fixture.header, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.development + "/x/support/include/New.h"))
        #expect(!FileManager.default.fileExists(atPath: fixture.sdks + "/iPhoneOS18.2-aaaaaaaa/usr/include/New.h"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `only an absolute path inside a root reaches it; a relative one, a link and anywhere else stay outside`() async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        // A link in the project to the extensions, and one in an SDK that
        // leads out of it.
        try FileManager.default.createSymbolicLink(atPath: fixture.home.projectURL.appendingPathComponent("development").path, withDestinationPath: fixture.development)
        try FileManager.default.createSymbolicLink(atPath: fixture.sdks + "/iPhoneOS18.2-aaaaaaaa/usr/include/escape.txt", withDestinationPath: fixture.outside.path)
        let relative = "../../../../jb/usr/share/apelin/development/x/support/include/Preferences/PSListController.h"
        for mode in Self.modes {
            for arguments: JSONValue in [
                ["path": .string(relative)],
                ["path": "development/x/support/include/Preferences/PSListController.h"],
                ["path": .string(fixture.sdks + "/iPhoneOS18.2-aaaaaaaa/usr/include/escape.txt")],
                ["path": .string(fixture.outside.path)],
                ["path": "/etc/hosts"],
                ["path": .string(fixture.header + "\0")],
            ] {
                let refusal = await fixture.refusal(.fileRead, arguments, mode: mode)
                #expect(refusal?.hasPrefix("refused: ") == true, "\(mode) \(arguments): \(refusal ?? "ran")")
            }
            let listed = await fixture.refusal(.fileList, ["path": "development"], mode: mode)
            #expect(listed?.hasPrefix("refused: ") == true, "\(mode): \(listed ?? "ran")")
        }
        // The refusal says where else the read tools read.
        let refusal = try #require(await fixture.refusal(.fileRead, ["path": .string(fixture.outside.path)], mode: .confirm))
        #expect(refusal.contains("is outside the project; the file tools also read, never write, an absolute path inside Apelin's development extensions (\(fixture.development)) or the registered SDKs (\(fixture.sdks))"), "\(refusal)")
        // A write's refusal does not offer what it cannot do.
        let write = try #require(await fixture.refusal(.fileWrite, ["path": .string(fixture.outside.path), "content": "x"], mode: .relaxed))
        #expect(!write.contains("also read"), "\(write)")
    }

    @Test(.timeLimit(.minutes(1)))
    func `without read-only roots nothing outside the project is read`() async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        let runner = try ToolRunner(
            sessionID: UUID().uuidString,
            project: fixture.home.project,
            root: ScopedRoot(fixture.home.projectURL),
            policy: ApprovalPolicy(mode: .relaxed),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            gate: ApprovalGate { _ in },
        )
        await #expect(throws: ToolDeniedError.self) {
            _ = try await runner.run(.local(.fileRead), toolCallID: "read", arguments: ["path": .string(fixture.header)], cancellation: nil, mcp: nil)
        }
    }
}
