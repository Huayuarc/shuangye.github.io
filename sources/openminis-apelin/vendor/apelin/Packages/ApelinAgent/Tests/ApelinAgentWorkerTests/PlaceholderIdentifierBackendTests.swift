import ApelinAgent
@testable import ApelinAgentWorker
import ApelinProtocol
import Foundation
import Testing

/// apelin_project_create's result names the identifiers Apelin made up for
/// the project, read from the folder `projectCreate` made, so the chat that
/// made it asks the user before the first install.
@Suite("A new project's placeholder identifiers")
struct PlaceholderIdentifierBackendTests {
    /// Answers `projectCreate` with a folder under `Projects/` holding
    /// `manifest`, and an app's Info.plist naming `bundleID` when given.
    private func create(
        _ fixture: Fixture,
        name: String = "Banana",
        manifest: String?,
        bundleID: String? = nil,
    ) async throws -> ProjectCreateToolResponse {
        let folder = fixture.dataFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        if let manifest {
            try manifest.write(to: folder.appendingPathComponent("apelin-project.json"), atomically: true, encoding: .utf8)
        }
        if let bundleID {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
            try plist.write(to: folder.appendingPathComponent("Resources/Info.plist"))
        }
        fixture.host.on(.projectCreate, reply: ProjectCreateResponse(projectID: "p-1", name: name, path: folder.path))
        return try await fixture.backend.createProject(ProjectCreateToolRequest(
            context: fixture.context(),
            templateID: "wiki.qaq.apelin.dev.app/uikit-objc",
            name: name,
        ))
    }

    private static func manifest(packageID: String) -> String {
        #"{"schemaVersion":1,"projectID":"p-1","kind":"app","products":[{"id":"app","type":"app","name":"Banana","sources":["Sources/*.m"],"infoPlist":"Resources/Info.plist"}],"package":{"id":"\#(packageID)"}}"#
    }

    @Test
    func `a new app's made-up package and bundle IDs are named, to ask about before its first install`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dataFolder) }
        let created = try await create(fixture, manifest: Self.manifest(packageID: "local.apelin.banana"), bundleID: "local.apelin.banana")
        #expect(created.identifierHint == "Its package ID local.apelin.banana and app bundle ID local.apelin.banana are placeholders Apelin made up. Before its first install the user should choose permanent ones, kept the same for debug and release builds: ask here and pass them on in the prompt of the conversation you open for it, or tell that conversation to ask.")
    }

    @Test
    func `identifiers the user chose, a workspace and a folder that is not there carry no note`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dataFolder) }
        let chosen = try await create(fixture, manifest: Self.manifest(packageID: "com.example.banana"), bundleID: "com.example.banana")
        #expect(chosen.identifierHint == nil)

        let workspace = try await create(fixture, name: "Imported", manifest: #"{"schemaVersion":1,"projectID":"p-2","kind":"workspace","buildSystem":"external"}"#)
        #expect(workspace.identifierHint == nil)

        fixture.host.on(.projectCreate, reply: ProjectCreateResponse(projectID: "p-3", name: "Elsewhere", path: "/nonexistent"))
        let missing = try await fixture.backend.createProject(ProjectCreateToolRequest(context: fixture.context(), templateID: "t", name: "Elsewhere"))
        #expect(missing.identifierHint == nil && missing.projectID == "p-3")
    }

    @Test
    func `a folder that leads out of Projects is not read`() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.dataFolder) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Self.manifest(packageID: "local.apelin.banana").write(to: outside.appendingPathComponent("apelin-project.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.dataFolder.appendingPathComponent("Linked"), withDestinationURL: outside)

        fixture.host.on(.projectCreate, reply: ProjectCreateResponse(projectID: "p-4", name: "Linked", path: outside.path))
        let linked = try await fixture.backend.createProject(ProjectCreateToolRequest(context: fixture.context(), templateID: "t", name: "Linked"))
        #expect(linked.identifierHint == nil)
    }
}
