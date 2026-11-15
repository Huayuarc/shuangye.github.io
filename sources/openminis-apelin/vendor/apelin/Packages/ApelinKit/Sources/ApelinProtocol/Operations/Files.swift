import Foundation

// Files: scoped reads answered with a read-only descriptor, and the app's
// manual protected edit (replace an existing regular file's contents, backup
// first, one grant per save). Workers may never call the protected edit.
// Served by the session host (Apelind/Dispatch/FilesHandler.swift).
//
// The protected edit, end to end:
//
// 1. `protectedEditOpen{path}` — the app's manual pick of a file inside the
//    bootstrap install root. The host canonicalises it, refuses what the
//    edit may never touch (a symlink, a hard-linked file, an executable, a
//    Mach-O, the package managers' own records, a file outside the install
//    root), and answers a read-only descriptor, the file's version and a
//    short-lived `grantID` bound to that file and that version.
// 2. `protectedEditCommit{grantID, contents, expectedVersion}` — the save.
//    The host checks the file is still the one it granted, backs the old
//    contents up to `~/Documents/wiki.qaq.apelin/backups/`, and replaces the
//    contents atomically, keeping owner, group and mode. The grant is spent
//    whatever the outcome. A LaunchDaemons plist needs `confirmed: true`.

/// Identifies one version of a file: what the commit must still find.
public struct FileVersion: Codable, Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modified: Double
    public var sha256: String?

    public init(device: UInt64, inode: UInt64, size: Int64, modified: Double, sha256: String? = nil) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
        self.sha256 = sha256
    }
}

public struct FileReadRequest: OperationRequest {
    public typealias Response = FileReadResponse
    public static let operation = AppOperation.fileRead
    /// A scope the host resolves: a project ID (or `project:<name>`),
    /// `sdk:<id>`, `extension:<id>`, `agent-tools:<id>`, or `grant:<grantID>`
    /// from `protectedEditOpen` (app only; `relativePath` empty).
    public var scopeID: String
    public var relativePath: String

    public init(scopeID: String, relativePath: String) {
        self.scopeID = scopeID
        self.relativePath = relativePath
    }
}

public struct FileReadResponse: Codable, Sendable, Equatable {
    /// A read-only descriptor in the reply's descriptor list.
    public var descriptor: DescriptorSlot
    public var version: FileVersion
    /// The canonical path the scope resolved to.
    public var path: String

    public init(descriptor: DescriptorSlot, version: FileVersion, path: String) {
        self.descriptor = descriptor
        self.version = version
        self.path = path
    }
}

public struct ProtectedEditOpenRequest: OperationRequest {
    public typealias Response = ProtectedEditOpenResponse
    public static let operation = AppOperation.protectedEditOpen
    /// The file the user picked, absolute, inside the install root `hello`
    /// answered.
    public var path: String
    public init(path: String) {
        self.path = path
    }
}

public struct ProtectedEditOpenResponse: Codable, Sendable, Equatable {
    /// One save of this file at this version; expires after `expiresIn` seconds.
    public var grantID: String
    public var expiresIn: Int
    /// The current contents, read-only.
    public var descriptor: DescriptorSlot
    /// Canonical.
    public var path: String
    public var version: FileVersion
    /// True for a LaunchDaemons plist: the save shows a diff and asks once,
    /// and the commit carries `confirmed: true`.
    public var needsConfirmation: Bool
    /// Earlier backups of this file, newest first, to offer "restore".
    public var backups: [String]

    public init(
        grantID: String,
        expiresIn: Int,
        descriptor: DescriptorSlot,
        path: String,
        version: FileVersion,
        needsConfirmation: Bool = false,
        backups: [String] = [],
    ) {
        self.grantID = grantID
        self.expiresIn = expiresIn
        self.descriptor = descriptor
        self.path = path
        self.version = version
        self.needsConfirmation = needsConfirmation
        self.backups = backups
    }
}

public struct ProtectedEditCommitRequest: OperationRequest {
    public typealias Response = ProtectedEditCommitResponse
    public static let operation = AppOperation.protectedEditCommit
    public var grantID: String
    /// The new contents, in the request's descriptor list…
    public var contents: DescriptorSlot?
    /// …or inline, base64, for a small file (the console has no descriptors).
    public var contentsBase64: String?
    public var expectedVersion: FileVersion
    /// Required for a file whose open answered `needsConfirmation`.
    public var confirmed: Bool

    public init(
        grantID: String,
        contents: DescriptorSlot?,
        contentsBase64: String? = nil,
        expectedVersion: FileVersion,
        confirmed: Bool = false,
    ) {
        self.grantID = grantID
        self.contents = contents
        self.contentsBase64 = contentsBase64
        self.expectedVersion = expectedVersion
        self.confirmed = confirmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grantID = try container.decode(String.self, forKey: .grantID)
        contents = try container.decodeIfPresent(DescriptorSlot.self, forKey: .contents)
        contentsBase64 = try container.decodeIfPresent(String.self, forKey: .contentsBase64)
        expectedVersion = try container.decode(FileVersion.self, forKey: .expectedVersion)
        confirmed = try container.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
    }
}

public struct ProtectedEditCommitResponse: Codable, Sendable, Equatable {
    public var version: FileVersion
    /// The backup under `~/Documents/wiki.qaq.apelin/backups/`.
    public var backupID: String

    public init(version: FileVersion, backupID: String) {
        self.version = version
        self.backupID = backupID
    }
}

public extension ApelinService {
    /// The read-only descriptor comes back owned by the caller.
    func fileRead(scopeID: String, relativePath: String) async throws -> (FileReadResponse, OwnedDescriptor?) {
        let (response, descriptors) = try await sendReturningDescriptors(
            FileReadRequest(scopeID: scopeID, relativePath: relativePath),
        )
        return (
            response,
            descriptors.indices.contains(response.descriptor.index) ? descriptors[response.descriptor.index] : nil,
        )
    }

    func protectedEditOpen(path: String) async throws -> (ProtectedEditOpenResponse, OwnedDescriptor?) {
        let (response, descriptors) = try await sendReturningDescriptors(ProtectedEditOpenRequest(path: path))
        return (
            response,
            descriptors.indices.contains(response.descriptor.index) ? descriptors[response.descriptor.index] : nil,
        )
    }

    /// `contents` is sent as descriptor 0.
    func protectedEditCommit(
        grantID: String,
        contents: OwnedDescriptor,
        expectedVersion: FileVersion,
        confirmed: Bool = false,
    ) async throws -> ProtectedEditCommitResponse {
        let request = ProtectedEditCommitRequest(
            grantID: grantID,
            contents: DescriptorSlot(index: 0),
            expectedVersion: expectedVersion,
            confirmed: confirmed,
        )
        return try await send(request, descriptors: [contents])
    }
}
