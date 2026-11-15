@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("A preset the host does not count asks the user")
struct RunCodeFallbackTests {
    @Test
    func `the host refuses a preset: the user is asked, and the call runs with the approval`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("Sources/Tweak.m", "// tweak\n")
        await harness.backend.setRefusesPresets(true)

        let (result, asked) = try await harness.run(.shellRun, ["argv": ["cat", "Sources/Tweak.m"]])
        #expect(asked.count == 1)
        guard case .command(.argv(["cat", "Sources/Tweak.m"])) = asked.first?.detail else {
            Issue.record("the card shows the command: \(String(describing: asked.first?.detail))"); return
        }
        let evidence = await harness.backend.runCodeEvidence
        #expect(evidence.count == 2)
        guard evidence.count == 2 else { return }
        #expect(evidence[0] == .preset("cat"))
        guard case let .user(requestID, _) = evidence[1] else {
            Issue.record("the retry carries the user's approval: \(evidence[1])"); return
        }
        #expect(requestID == asked.first?.id)
        #expect(await harness.backend.calls == [.runCode(.argv(["cat", "Sources/Tweak.m"]))])
        #expect(result.content.isEmpty == false)
    }

    @Test
    func `a refusal is not remembered: once the host counts the call, it goes as a preset again`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("Sources/Tweak.m", "// tweak\n")
        await harness.backend.setRefusesPresets(true)
        let call: JSONValue = ["argv": ["cat", "Sources/Tweak.m"]]

        let (_, first) = try await harness.run(.shellRun, call)
        #expect(first.count == 1)

        // The repository changed (a `git init`, a clone): the host now
        // counts the same call as a preset, and nobody is asked.
        await harness.backend.setRefusesPresets(false)
        let (_, second) = try await harness.run(.shellRun, call)
        #expect(second.isEmpty, "the user is not asked again: \(second)")
        let evidence = await harness.backend.runCodeEvidence
        #expect(evidence.count == 3, "refused preset, user's approval, then a preset: \(evidence)")
        #expect(evidence.last == .preset("cat"))
    }

    @Test
    func `the user declines the fallback: the call is refused and not retried`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("Sources/Tweak.m", "// tweak\n")
        await harness.backend.setRefusesPresets(true)

        await #expect(throws: ToolDeniedError.self) {
            _ = try await harness.run(.shellRun, ["argv": ["cat", "Sources/Tweak.m"]], answering: .deny(reason: nil))
        }
        #expect(await harness.backend.runCodeEvidence == [.preset("cat")])
        #expect(await harness.backend.calls.isEmpty)
    }
}
