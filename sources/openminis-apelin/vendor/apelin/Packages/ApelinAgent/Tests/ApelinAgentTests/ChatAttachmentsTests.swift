@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Chat attachments and temporary workspaces")
struct ChatAttachmentsTests {
    @Test
    func `Attachments persist, replay and deduplicate a retried send`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("Read the attachment."))])
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let id = UUID()
        let data = Data("# Shared notes\nHello from a file.".utf8)
        try await session.prompt("Read this", messageID: id, files: [("../notes.md", "text/markdown", data)])
        await session.waitForIdle()
        try await session.prompt("Read this", messageID: id, files: [("../notes.md", "text/markdown", data)])
        let records = try await session.log.records(afterSeq: 0)
        let messages = records.compactMap { record -> [ApelinProtocol.AgentAttachment]? in
            if case let .userMessage(messageID, _, files) = record.event, messageID == id {
                return files
            }
            return nil
        }
        #expect(messages.count == 1)
        let file = try #require(messages.first?.first)
        #expect(file.name == "../notes.md")
        #expect(file.path.hasPrefix("Attachments/"))
        #expect(try Data(contentsOf: home.projectURL.appendingPathComponent(file.path)) == data)
        await session.close()
        let resumed = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await resumed.prompt("Read this", messageID: id)
        #expect(try await resumed.log.records(afterSeq: 0).filter {
            if case .userMessage = $0.event {
                return true
            }; return false
        }.count == 1)
        await resumed.close()
    }

    @Test
    func `Tool images survive the event log as saved attachments`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_screen_capture", arguments: ["reason": "Look at the screen"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Here is the screen.")),
        ])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.prompt("Capture the screen")
        await session.waitForIdle()
        let records = try await session.log.records(afterSeq: 0)
        let files = records.compactMap { record -> ApelinProtocol.AgentAttachment? in
            if case let .toolCallFinished(result) = record.event {
                return result.attachments?.first
            }
            return nil
        }
        let file = try #require(files.first)
        #expect(file.mimeType == "image/png")
        #expect(try Data(contentsOf: home.projectURL.appendingPathComponent(file.path)) == Data([0x89, 0x50]))
        await session.close()
    }

    @Test
    func `A temporary chat is confined to its own UUID directory`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let folder = home.dataRoot.url.appendingPathComponent("Temporary/" + id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let identity = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        let configuration = AgentSessionConfiguration(project: identity, temporaryID: id, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await session.close()
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: home.projectURL)
        await #expect(throws: (any Error).self) {
            _ = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        }
    }
}
