@testable import ApelinAgent
import struct ApelinProtocol.AgentAttachment
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// file_show: a project file the user asked to see goes into the
/// conversation as an attachment, a copy of it as it was then.
@Suite("Showing project files to the user")
struct FileShowTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
    static let pdf = Data("%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n".utf8)

    let home: TemporaryHome
    let tools: ProjectFileTools

    init() throws {
        home = try TemporaryHome()
        try home.write("Sources/Tweak.m", "// tweak\n")
        try home.write("Makefile", "all:\n\tclang Tweak.m\n")
        try FileManager.default.createDirectory(at: home.projectURL.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Self.png.write(to: home.projectURL.appendingPathComponent("Resources/icon.png"))
        try Self.pdf.write(to: home.projectURL.appendingPathComponent("notes.pdf"))
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00]).write(to: home.projectURL.appendingPathComponent("Tweak.dylib-part"))
        tools = try ProjectFileTools(root: ScopedRoot(home.projectURL))
    }

    private func shown(_ result: AgentToolResult) -> [AgentAttachment] {
        FileShow.attachments(of: AgentToolName.fileShow.rawValue, result: result, isError: false)
    }

    private func copy(_ file: AgentAttachment) throws -> Data {
        try Data(contentsOf: home.projectURL.appendingPathComponent(file.path))
    }

    private var attachmentsFolder: URL {
        home.projectURL.appendingPathComponent("Attachments")
    }

    @Test
    func `an image and a PDF are copied with their names and types`() throws {
        defer { home.remove() }
        let result = try tools.show(["paths": ["Resources/icon.png", "notes.pdf", "Resources/icon.png"]])
        let files = shown(result)
        #expect(files.map(\.name) == ["icon.png", "notes.pdf"], "a file named twice is shown once")
        #expect(files.map(\.mimeType) == ["image/png", "application/pdf"])
        #expect(files.allSatisfy { $0.path.hasPrefix("Attachments/") })
        #expect(try files.map(copy) == [Self.png, Self.pdf])
        guard case let .text(text)? = result.content.first else {
            Issue.record("no text for the model")
            return
        }
        #expect(text.text == "Shown to the user in this conversation: Resources/icon.png, notes.pdf.")
        // The user sees the file as it was: a later edit leaves the copy.
        try Data("%PDF-1.7 rewritten".utf8).write(to: home.projectURL.appendingPathComponent("notes.pdf"))
        #expect(try copy(files[1]) == Self.pdf)
    }

    @Test
    func `text without a type of its own reads as text, other bytes as bytes`() throws {
        defer { home.remove() }
        let files = try shown(tools.show(["paths": ["Makefile", "Sources/Tweak.m", "Tweak.dylib-part"]]))
        #expect(files.map(\.mimeType) == ["text/plain", "text/plain", "application/octet-stream"], "\(files.map(\.mimeType))")
    }

    @Test
    func `only a failed call or another tool's result carries no copies`() throws {
        defer { home.remove() }
        let result = try tools.show(["paths": ["notes.pdf"]])
        #expect(shown(result).count == 1)
        #expect(FileShow.attachments(of: AgentToolName.fileShow.rawValue, result: result, isError: true).isEmpty)
        #expect(FileShow.attachments(of: AgentToolName.fileRead.rawValue, result: result, isError: false).isEmpty)
        #expect(FileShow.attachments(of: "mcp__docs__file_show", result: result, isError: false).isEmpty)
    }

    @Test
    func `what is outside, not a file, too many or too large is refused, and nothing is copied`() throws {
        defer { home.remove() }
        let outside = home.home.appendingPathComponent("outside.png")
        try Self.png.write(to: outside)
        try FileManager.default.createSymbolicLink(at: home.projectURL.appendingPathComponent("leak.png"), withDestinationURL: outside)
        #expect(mkfifo(home.projectURL.appendingPathComponent("pipe").path, 0o644) == 0)
        let large = home.projectURL.appendingPathComponent("large.mov")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        try resize(large, to: AgentSession.maximumAttachmentBytes + 1)

        let refusals: [[String]] = [
            ["notes.pdf", "../outside.png"],
            ["notes.pdf", "leak.png"],
            ["notes.pdf", outside.path],
            ["notes.pdf", "Resources"],
            ["notes.pdf", "pipe"],
            ["notes.pdf", "large.mov"],
            ["notes.pdf", "missing.png"],
            Array(repeating: "notes.pdf", count: FileShow.maximumFiles + 1),
            [],
        ]
        for paths in refusals {
            #expect(throws: (any Error).self, "\(paths)") {
                _ = try tools.show(["paths": .array(paths.map { .string($0) })])
            }
        }
        #expect(throws: (any Error).self) { _ = try tools.show([:]) }
        #expect(!FileManager.default.fileExists(atPath: attachmentsFolder.path), "a refused call copies nothing")
        // The largest file allowed is shown.
        try resize(large, to: AgentSession.maximumAttachmentBytes)
        #expect(try shown(tools.show(["paths": ["large.mov"]])).map(\.mimeType) == ["video/quicktime"])
    }

    /// A sparse file of `size` bytes.
    private func resize(_ url: URL, to size: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    @Test
    func `Strict lets it through as a read preset, and never out of the project`() throws {
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        let strict = ApprovalPolicy(mode: .confirm)
        #expect(strict.evaluate(InvocationFacts(tool: .local(.fileShow), pathCheck: .inside), root: root) == .allow(.preset("file_show")))
        for mode in [ApprovalMode.relaxed, .confirm, .full] {
            let verdict = ApprovalPolicy(mode: mode).evaluate(InvocationFacts(tool: .local(.fileShow), pathCheck: .outside("../x.png")), root: root)
            guard case .deny = verdict else {
                Issue.record("\(mode): \(verdict)")
                continue
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a session hands the copies to the call's result, asking nothing in Strict mode`() async throws {
        defer { home.remove() }
        try Self.png.write(to: home.home.appendingPathComponent("outside.png"))
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "file_show", arguments: [
                "paths": ["notes.pdf", "../outside.png"],
                "reason": "Show the notes",
            ])], stopReason: .toolUse)),
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "file_show", arguments: [
                "paths": ["notes.pdf"],
                "reason": "Show the notes",
            ])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Here are the notes.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Let me see the notes")
        await session.waitForIdle()
        let records = try await session.log.records(afterSeq: 0)
        #expect(!records.contains {
            if case .approvalRequested = $0.event {
                return true
            }
            return false
        })
        let results = records.compactMap { record -> ToolResultRecord? in
            if case let .toolCallFinished(result) = record.event {
                return result
            }
            return nil
        }
        #expect(results.map(\.isError) == [true, false])
        #expect(results.first?.attachments?.isEmpty == true, "a refused call shows nothing")
        let file = try #require(results.last?.attachments?.first)
        #expect(results.last?.attachments?.count == 1)
        #expect(file.name == "notes.pdf" && file.mimeType == "application/pdf")
        #expect(try copy(file) == Self.pdf)
        await session.close()
    }
}
