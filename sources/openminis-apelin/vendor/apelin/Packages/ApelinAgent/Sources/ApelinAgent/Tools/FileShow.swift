import struct ApelinProtocol.AgentAttachment
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import UniformTypeIdentifiers

/// `file_show`: project files put in the conversation for the user, the way
/// a tool's image is. Each is copied into the workspace's `Attachments/` as
/// it is now, so a later edit does not change what was shown, and the
/// copies are listed in the result's `details`, which no provider reads.
/// The session hands them to the call's `toolResult` event, and the app
/// shows them as it shows any attachment: images in an album, other files
/// as cards, each opening in Quick Look. An extension tool's returned files
/// go the same way (`ToolRunner.runExtension`).
enum FileShow {
    /// The most files one call shows, as many as a message carries.
    static let maximumFiles = 8
    private static let detailsKey = "shown"

    /// The copies a file_show call made; none for a failed call or any other
    /// tool's.
    static func attachments(of tool: String, result: AgentToolResult, isError: Bool) -> [AgentAttachment] {
        guard tool == AgentToolName.fileShow.rawValue, !isError else { return [] }
        return copies(in: result.details)
    }

    /// The copies `details(_:)` lists.
    static func copies(in details: JSONValue?) -> [AgentAttachment] {
        guard case let .object(details)? = details, case let .array(items)? = details[detailsKey] else { return [] }
        return items.compactMap { item in
            guard case let .object(fields) = item, case let .string(path)? = fields["path"],
                  case let .string(name)? = fields["name"], case let .string(mimeType)? = fields["mimeType"]
            else { return nil }
            return AgentAttachment(path: path, name: name, mimeType: mimeType)
        }
    }

    /// The copies, as a result's `details`, which no provider reads.
    static func details(_ copies: [AgentAttachment]) -> JSONValue {
        .object([detailsKey: .array(copies.map { copy in
            .object(["path": .string(copy.path), "name": .string(copy.name), "mimeType": .string(copy.mimeType)])
        })])
    }

    /// What the model reads, the shown paths, and the copies for the session.
    static func result(_ copies: [AgentAttachment], paths: [String]) -> AgentToolResult {
        AgentToolResult(
            content: [.text(TextContent(text: "Shown to the user in this conversation: \(paths.joined(separator: ", "))."))],
            details: details(copies),
        )
    }

    /// The type the app shows a copy as: its extension's, else plain text
    /// for what reads as text (a Makefile, a Logos file), else bytes.
    static func mimeType(of name: String, data: Data) -> String {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if let mimeType = type?.preferredMIMEType {
            return mimeType
        }
        if type?.conforms(to: .text) == true || !data.prefix(8192).contains(0) {
            return "text/plain"
        }
        return "application/octet-stream"
    }
}

extension ProjectFileTools {
    /// Copies the files `paths` names into `Attachments/` for the user to
    /// see. Every one is checked before any is copied — a regular file
    /// inside the project, at most `AgentSession.maximumAttachmentBytes` —
    /// and when a copy fails, those already made are taken back.
    func show(_ arguments: JSONValue) throws -> AgentToolResult {
        guard let paths = arguments.argStrings("paths"), !paths.isEmpty else {
            throw ToolArgumentError("paths must be a non-empty list of project-relative paths")
        }
        guard paths.count <= FileShow.maximumFiles else {
            throw ToolArgumentError("paths names \(paths.count) files; show at most \(FileShow.maximumFiles) at a time")
        }
        let limit = AgentSession.maximumAttachmentBytes
        var files: [String] = []
        for path in paths {
            let real = try root.resolveExisting(path)
            var info = stat()
            guard lstat(real, &info) == 0 else { throw PathPolicyError.notFound(path) }
            switch info.st_mode & S_IFMT {
            case S_IFREG: break
            case S_IFDIR: throw ToolArgumentError("\(path) is a folder: show the files in it")
            default: throw PathPolicyError.notAFile(path)
            }
            guard Int(info.st_size) <= limit else {
                throw ToolArgumentError("\(path) is \(info.st_size) bytes; a file shown is at most \(limit >> 20) MB")
            }
            if !files.contains(real) {
                files.append(real)
            }
        }
        var copies: [AgentAttachment] = []
        do {
            for file in files {
                let data = try readData(file, limit: limit)
                let name = String((file as NSString).lastPathComponent.prefix(255))
                // Named as the session names a tool's image (`saveAttachment`).
                let path = "Attachments/" + UUID().uuidString.lowercased()
                try root.resolveForWrite(path).commit(data, exclusive: true)
                copies.append(AgentAttachment(path: path, name: name, mimeType: FileShow.mimeType(of: name, data: data)))
            }
        } catch {
            for copy in copies {
                unlink((root.path as NSString).appendingPathComponent(copy.path))
            }
            throw error
        }
        return FileShow.result(copies, paths: files.map(root.relative))
    }
}
