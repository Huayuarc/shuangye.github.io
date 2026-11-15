@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

/// A workspace's build and install from the agent's side: the build runs
/// the workspace's own script and asks every time in Strict mode, never for
/// the session; the package it made is installed under the packaging rule.
@Suite("Workspace builds")
struct ExternalBuildToolTests {
    private static let manifest = #"{"schemaVersion":1,"projectID":"x","kind":"workspace","buildSystem":"external","external":{"script":"apelin/build.sh"}}"#

    @Test
    func `a workspace's build asks every time, naming its script, and is never granted for the session`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest)
        let asked = ExternalBuildApproval(projectID: harness.home.project.id, script: "apelin/build.sh", configuration: "debug", bootstrap: nil)

        let (_, first) = try await harness.run(.projectBuild, [:], answering: .approve(.session))
        #expect(first.count == 1)
        #expect(first.first?.detail == .externalBuild(asked))
        #expect(first.first?.allowsSessionScope == false)
        let (_, second) = try await harness.run(.projectBuild, ["configuration": "release", "bootstrap": "rootless"])
        #expect(second.first?.detail == .externalBuild(ExternalBuildApproval(
            projectID: harness.home.project.id,
            script: "apelin/build.sh",
            configuration: "release",
            bootstrap: "rootless",
        )), "a session answer granted nothing: the next build asks again")

        let calls = await harness.backend.calls
        #expect(calls.count == 2)
        for (call, request) in zip(calls, first + second) {
            #expect(call == .build(digest: "", evidence: .user(requestID: request.id, fingerprint: request.fingerprint)))
        }
    }

    @Test
    func `in Relaxed mode a workspace builds without asking`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .relaxed)
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest)
        let (_, asked) = try await harness.run(.projectBuild, [:])
        #expect(asked.isEmpty)
        #expect(await harness.backend.calls == [.build(digest: "", evidence: .relaxed)])
    }

    @Test
    func `a workspace's install is judged by the package it built`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest)
        await harness.ledger.addArtifact("a1", packaging: "sha256:package-1")

        let (_, first) = try await harness.run(.packageInstall, ["artifact_id": "a1", "artifact_digest": "d1"])
        guard case let .descriptionChanged(kind, digest, _)? = first.first?.detail else {
            Issue.record("the first install asks about the package: \(first)")
            return
        }
        #expect(kind == .packaging && digest == "sha256:package-1")
        let (_, again) = try await harness.run(.packageInstall, ["artifact_id": "a1", "artifact_digest": "d1"])
        #expect(again.isEmpty, "an approved package installs again without asking")

        await #expect(throws: ToolArgumentError.self) {
            _ = try await harness.run(.packageInstall, ["artifact_id": "unknown", "artifact_digest": "d"])
        }
    }
}
