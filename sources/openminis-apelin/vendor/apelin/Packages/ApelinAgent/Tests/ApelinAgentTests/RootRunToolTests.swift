@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAI
import Testing

/// shell_run as root, from the agent's side: what it sends to the host and
/// what the approval card is built from. The host decides again
/// (Tests/SessionHost/RootRunChecks.swift); these pin that the two halves
/// describe the same call.
@Suite("shell_run as root")
struct RootRunToolTests {
    /// A call that does not say `root: true` asks for nothing more than
    /// mobile, in every mode, whatever else the model put there.
    @Test
    func `a call without root true is sent as mobile in every mode`() async throws {
        for mode in [ApprovalMode.confirm, .relaxed, .full] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            let shapes: [JSONValue] = [
                ["argv": ["make"]],
                ["argv": ["make"], "root": false],
                ["argv": ["make"], "root": .null],
                ["argv": ["make"], "root": "true"],
                ["argv": ["make"], "root": 1],
            ]
            for arguments in shapes {
                let (_, asked) = try await harness.run(.shellRun, arguments)
                #expect(!asked.contains(where: Self.isRootCard), "\(mode) \(arguments): no root card")
            }
            let sent = await harness.backend.runCodeRequests
            #expect(sent.count == shapes.count, "\(mode): every call ran")
            #expect(sent.allSatisfy { !$0.asRoot }, "\(mode): none asked for root: \(sent)")
        }
    }

    /// Each shape a root call can take: the card's `rootCommand` and its
    /// working directory are exactly the invocation and directory the
    /// request carries, and every argument the run reads is on the card.
    @Test
    func `the root card names exactly the command and directory that are sent`() async throws {
        let cases: [(arguments: JSONValue, invocation: RunCodeInvocation, directory: String)] = [
            (["argv": ["irisin-cli", "install", "--yes", "x"], "root": true], .argv(["irisin-cli", "install", "--yes", "x"]), "."),
            (["command": "irisin-cli install --yes x", "root": true], .argv(["irisin-cli", "install", "--yes", "x"]), "."),
            (["command": "irisin-cli install --yes x | tee log", "root": true], .shell("irisin-cli install --yes x | tee log"), "."),
            (["script": "print(1)", "interpreter": "python3", "root": true], .script(interpreter: "python3", source: "print(1)"), "."),
            (["script": "id -u", "root": true], .script(interpreter: "sh", source: "id -u"), "."),
            (["argv": ["id"], "cwd": "", "root": true], .argv(["id"]), "."),
            (["argv": ["id"], "cwd": "Sources", "root": true], .argv(["id"]), "Sources"),
        ]
        for mode in [ApprovalMode.confirm, .relaxed] {
            for (arguments, invocation, directory) in cases {
                let harness = try DigestApprovalTests.Harness(mode: mode)
                defer { harness.home.remove() }
                try harness.home.write("Sources/.keep", "")
                let (_, asked) = try await harness.run(.shellRun, arguments)
                #expect(asked.count == 1, "\(mode) \(arguments): one card")
                guard let card = asked.first else { continue }
                #expect(card.detail == .rootCommand(invocation), "\(mode) \(arguments): \(card.detail)")
                #expect(card.workingDirectory == directory)
                #expect(card.allowsSessionScope == false, "a root card never offers the session")
                let sent = await harness.backend.runCodeRequests
                #expect(sent.count == 1)
                #expect(sent.first?.invocation == invocation)
                #expect(sent.first?.workingDirectory == card.workingDirectory)
                #expect(sent.first?.asRoot == true)
                guard case let .user(requestID, _)? = sent.first?.context.approval else {
                    Issue.record("\(mode) \(arguments): sent with the card's approval"); continue
                }
                #expect(requestID == card.id)
                // The card is read from the arguments by name: each field
                // the run uses is there as the model wrote it.
                let shown = try JSONDecoder().decode(JSONValue.self, from: Data(card.arguments.utf8)).objectValue
                let given = arguments.objectValue ?? [:]
                for key in ["argv", "command", "script", "interpreter"] where given[key] != nil {
                    #expect(shown?[key] == given[key], "\(key) is shown as sent")
                }
                #expect(shown?["root"] == .bool(true), "the card's arguments say root")
            }
        }
    }

    /// Full runs it without a card, still as a root request the host
    /// checks against its own record of the mode.
    @Test
    func `Full sends a root call without asking, marked as root`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .full)
        defer { harness.home.remove() }
        let (_, asked) = try await harness.run(.shellRun, ["argv": ["irisin-cli", "install", "--yes", "x"], "root": true])
        #expect(asked.isEmpty)
        let sent = await harness.backend.runCodeRequests
        #expect(sent.count == 1)
        #expect(sent.first?.asRoot == true)
        #expect(sent.first?.context.approval == .relaxed, "evidence the host does not take as approval")
    }

    /// Leaving Full asks again on the next root call, in Relaxed and in
    /// Strict; Strict also asks again for an ordinary command outside the
    /// presets.
    @Test
    func `leaving Full asks again for the next root call`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .full)
        defer { harness.home.remove() }
        let call: JSONValue = ["argv": ["irisin-cli", "install", "--yes", "x"], "root": true]
        let (_, inFull) = try await harness.run(.shellRun, call)
        #expect(inFull.isEmpty)
        for mode in [ApprovalMode.relaxed, .confirm] {
            await harness.runner.setMode(mode)
            let (_, after) = try await harness.run(.shellRun, call)
            #expect(after.count == 1, "\(mode) asks")
        }
        let (_, ordinary) = try await harness.run(.shellRun, ["argv": ["make"]])
        #expect(ordinary.count == 1, "Strict asks for a command outside the presets")
    }

    private static func isRootCard(_ request: ApprovalRequest) -> Bool {
        if case .rootCommand = request.detail {
            return true
        }
        return false
    }
}
