import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("apelin_package_publish is one distributionPublish task")
struct PublishBackendTests {
    /// A data folder with a linked package repository's project and two
    /// release builds' records and packages, as apelin-build leaves them.
    struct DataFolder {
        let root: URL
        let host = FakeHost()
        let backend: ChannelHostBackend

        init(linked: Bool = true) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("apelin-publish-tests-\(UUID().uuidString)", isDirectory: true)
            let projects = root.appendingPathComponent("Projects", isDirectory: true)
            let repository = projects.appendingPathComponent("packages", isDirectory: true)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try #"{"projectID": "p-repo", "kind": "workspace"}"#.write(
                to: repository.appendingPathComponent("apelin-project.json"), atomically: true, encoding: .utf8,
            )
            let settings = root.appendingPathComponent("Settings", isDirectory: true)
            try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
            if linked {
                try #"""
                {"fullName": "someone/packages", "url": "https://github.com/someone/packages",
                 "sourceURL": "https://someone.github.io/packages/", "projectID": "p-repo", "projectName": "packages"}
                """#.write(to: settings.appendingPathComponent("distribution.json"), atomically: true, encoding: .utf8)
            }
            let project = try ApelinAgent.ProjectIdentity(id: "p-clock", name: ApelinAgent.ProjectName("Clock"))
            backend = ChannelHostBackend(
                service: ApelinService(transport: host),
                sessionID: "11111111-2222-4333-8444-555555555555",
                project: project,
                projectURL: projects.appendingPathComponent("Clock", isDirectory: true),
                projectsURL: projects,
            )
        }

        /// A build's record and, unless `gone`, its package.
        @discardableResult
        func build(_ id: String, configuration: String = "Release", bootstrap: String = "roothide", gone: Bool = false) throws -> String {
            let folder = root.appendingPathComponent("Builds/p-clock/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let deb = folder.appendingPathComponent("com.example.clock_1.0.deb").path
            if !gone {
                FileManager.default.createFile(atPath: deb, contents: Data("deb".utf8))
            }
            let artifacts = root.appendingPathComponent("Builds/artifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            let record: ApelinCore.JSONValue = .object([
                "artifactID": .string(id), "buildID": .string(id), "projectID": .string("p-clock"),
                "configuration": .string(configuration), "bootstrap": .string(bootstrap), "path": .string(deb),
                "digest": .string("sha256:" + String(repeating: "c", count: 64)), "packageID": .string("com.example.clock"),
                "packageVersion": .string("1.0"),
                "architecture": .string(bootstrap == "roothide" ? "iphoneos-arm64e" : "iphoneos-arm64"),
            ])
            try JSONCoding.encode(record).write(to: artifacts.appendingPathComponent("\(id).json"))
            return deb
        }

        func context() -> HostCallContext {
            HostCallContext(sessionID: backend.sessionID, project: backend.project, toolCallID: "call-1", approval: .relaxed)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let publication = PackagePublishApproval(
        repository: "someone/packages",
        sourceURL: "https://someone.github.io/packages/",
        packages: [
            .init(buildID: "b-hide", packageID: "com.example.clock", version: "1.0", architecture: "iphoneos-arm64e",
                  bootstrap: "roothide", file: "/data/Builds/p-clock/b-hide/a.deb", digest: "sha256:" + String(repeating: "a", count: 64)),
            .init(buildID: "b-less", packageID: "com.example.clock", version: "1.0", architecture: "iphoneos-arm64",
                  bootstrap: "rootless", file: "/data/Builds/p-clock/b-less/b.deb", digest: "sha256:" + String(repeating: "b", count: 64)),
        ],
    )

    @Test
    func `before asking it reads the link, the sign-in and each build's record`() async throws {
        let data = try DataFolder()
        defer { data.remove() }
        let deb = try data.build("b-hide")
        try data.build("b-debug", configuration: "Debug", bootstrap: "rootless")
        try data.build("b-gone", gone: true)
        data.host.on(.gitSettings, reply: GitSettingsResponse(credentials: [GitCredentialSummary(host: "github.com", username: "someone")]))

        let read = try await data.backend.packagePublication(PackagePublicationRequest(
            context: data.context(),
            buildIDs: ["b-hide", "b-debug", "b-gone", "b-nothing", "../escape"],
        ))
        #expect(read.repository == PackagePublication.Repository(fullName: "someone/packages", sourceURL: "https://someone.github.io/packages/"))
        #expect(read.signedIn == true)
        #expect(read.builds.count == 5)
        #expect(read.builds[0] == PackageBuildRecord(
            buildID: "b-hide", projectID: "p-clock", configuration: "Release", bootstrap: "roothide",
            packageID: "com.example.clock", version: "1.0", architecture: "iphoneos-arm64e", file: deb,
            digest: "sha256:" + String(repeating: "c", count: 64), present: true,
        ))
        #expect(read.builds[1]?.configuration == "Debug")
        #expect(read.builds[2]?.present == false, "a record whose package is gone")
        #expect(read.builds[3] == nil && read.builds[4] == nil, "no record, and an id that is no build's")
        #expect(data.host.requests.map(\.operation) == [.gitSettings], "nothing else asks the host")

        // Without a sign-in, and with the repository's project gone.
        data.host.on(.gitSettings, reply: GitSettingsResponse())
        try FileManager.default.removeItem(at: data.root.appendingPathComponent("Projects/packages"))
        let unlinked = try await data.backend.packagePublication(PackagePublicationRequest(context: data.context(), buildIDs: ["b-hide"]))
        #expect(unlinked.repository == nil && unlinked.signedIn == false)
    }

    @Test
    func `every package goes in one distributionPublish with its digest and the repository, read to the end`() async throws {
        let data = try DataFolder()
        defer { data.remove() }
        data.host.on(.distributionPublish, reply: TaskHandle(taskID: TaskID("publish-task"), kind: .environment))
        data.host.on(.environmentAttach, reply: batch("publish-task", [
            ("stage", .object(["stage": .string("fetching")])),
            ("result", .object([
                "published": .array([.string("com.example.clock_1.0_iphoneos-arm64e.deb")]),
                "skipped": .array([.string("com.example.clock_1.0_iphoneos-arm64.deb")]),
                "sourceURL": .string("https://someone.github.io/packages/"),
                "repository": .string("someone/packages"),
                "commit": .string("abc123"),
            ])),
            stateEvent(.succeeded),
        ]))
        let response = try await data.backend.publishPackages(PackagePublishToolRequest(context: data.context(), publication: Self.publication))

        let sent = try #require(data.host.requests(DistributionPublishRequest.self).first)
        #expect(data.host.requests.map(\.operation) == [.distributionPublish, .environmentAttach])
        #expect(sent.files == Self.publication.packages.map(\.file))
        #expect(sent.digests == Self.publication.packages.map(\.digest))
        #expect(sent.repository == "someone/packages")
        #expect(response.published == ["com.example.clock_1.0_iphoneos-arm64e.deb"])
        #expect(response.alreadyPublished == ["com.example.clock_1.0_iphoneos-arm64.deb"])
        #expect(response.commit == "abc123")
        #expect(response.next.contains("once the repository's workflow on GitHub has indexed debs/"))
        #expect(response.next.contains("the source to add is https://someone.github.io/packages/"))
    }

    @Test
    func `a refusal says what to do: Sign In with GitHub by the reason, else the host's words`() async throws {
        let data = try DataFolder()
        defer { data.remove() }
        data.host.on(.distributionPublish) { _ in
            throw ApelinError(.denied, "Sign in with GitHub in Settings ▸ Git first.", reason: .authenticationRequired)
        }
        await #expect {
            _ = try await data.backend.publishPackages(PackagePublishToolRequest(context: data.context(), publication: Self.publication))
        } throws: { error in
            (error as? PackagePublishToolFailure)?.message == PackagePublish.signInNeeded
        }

        data.host.on(.distributionPublish, reply: TaskHandle(taskID: TaskID("publish-task"), kind: .environment))
        data.host.on(.environmentAttach, reply: batch("publish-task", [
            stateEvent(.failed, "conflict: debs/com.example.clock_1.0_iphoneos-arm64e.deb is already published with other contents. Raise the version and build again."),
        ]))
        await #expect {
            _ = try await data.backend.publishPackages(PackagePublishToolRequest(context: data.context(), publication: Self.publication))
        } throws: { error in
            (error as? PackagePublishToolFailure)?.message
                == "Nothing was published: debs/com.example.clock_1.0_iphoneos-arm64e.deb is already published with other contents. Raise the version and build again."
        }
    }

    @Test
    func `the approval carries the repository, files and digests the host matches`() throws {
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "apelin_package_publish", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Publishes these 2 packages.",
            detail: .packagePublish(Self.publication), allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let detail = try #require(payload["detail"]?["packagePublish"])
        #expect(detail["repository"] == .string("someone/packages"))
        #expect(detail["sourceURL"] == .string("https://someone.github.io/packages/"))
        guard case let .array(packages)? = detail["packages"] else {
            Issue.record("no packages"); return
        }
        #expect(packages.map { $0["file"]?.stringValue } == Self.publication.packages.map(\.file))
        #expect(packages.map { $0["digest"]?.stringValue } == Self.publication.packages.map(\.digest))
        #expect(packages.first?["packageID"] == .string("com.example.clock"))
        #expect(packages.first?["architecture"] == .string("iphoneos-arm64e"))
        #expect(packages.first?["bootstrap"] == .string("roothide"))
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
