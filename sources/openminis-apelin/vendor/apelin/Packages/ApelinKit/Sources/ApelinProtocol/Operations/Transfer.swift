import ApelinCore
import Foundation

// Transfer files: a toolchain (`.apetc`), an iPhoneOS SDK (`.apesdk`) or a
// project (`.apeproj`) written on one device, sent anywhere, and opened in
// Apelin on another. Served by apelin-environment (Workers/Environment;
// ApelinEnvironment ▸ Transfer).
//
// A transfer file is a tar compressed with zstd. Its first member is
// `manifest.json` (`TransferManifest`); every other member is
// `payload/<path>` and is listed in the manifest with its kind, size and
// SHA-256. Nothing outside that list is read, and nothing in it may be
// missing.
//
// Export and import are tasks of kind `environment`, read with
// `environmentAttach` and stopped with `environmentCancel`.
// Export's events: `stage` {collecting | packing}, `progress` {stage,
// completed, total?, detail?}, `warning` {message}, and before the final
// `state` a `result` {export: TransferExport}.
// Import's: `stage` {reading}, then the kind's own — a toolchain's
// `sdk`?, `packaging`, `installing`, `validating` (and the `install.*`
// events of the host's install task, `artifact`, `sdkSource`,
// `sdkImported` as setup has them); an SDK's `inspecting`, `registering`;
// a project's `placing` — `progress`, `warning`, and a `result`
// {toolchain: ToolchainRecord | sdk: SDKRecord | project: TransferProjectResult}.

/// What a transfer file holds.
public enum TransferKind: String, Codable, Sendable, CaseIterable {
    case toolchain
    case sdk
    case project

    /// Without the dot: `apetc`, `apesdk`, `apeproj`.
    public var fileExtension: String {
        switch self {
        case .toolchain: "apetc"
        case .sdk: "apesdk"
        case .project: "apeproj"
        }
    }

    /// The exported type the app declares (`UTExportedTypeDeclarations`).
    public var typeIdentifier: String {
        switch self {
        case .toolchain: "wiki.qaq.apelin.toolchain-package"
        case .sdk: "wiki.qaq.apelin.sdk-package"
        case .project: "wiki.qaq.apelin.project-package"
        }
    }

    /// The kind a file name's extension says, compared without case.
    public init?(fileName: String) {
        let pathExtension = (fileName as NSString).pathExtension.lowercased()
        guard let kind = Self.allCases.first(where: { $0.fileExtension == pathExtension }) else { return nil }
        self = kind
    }
}

/// One payload member: `payload/<path>` in the archive.
public struct TransferMember: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
        case link
    }

    /// Relative to the payload root: plain components, no `..`, no NUL.
    public var path: String
    public var kind: Kind
    /// A file's size in bytes.
    public var size: Int64?
    /// A file's SHA-256, lowercase hex.
    public var sha256: String?
    /// A file with any execute bit; written 0755 (0644 otherwise).
    public var executable: Bool?
    /// A link's target: relative, and staying inside the payload.
    public var target: String?

    public init(
        path: String,
        kind: Kind,
        size: Int64? = nil,
        sha256: String? = nil,
        executable: Bool? = nil,
        target: String? = nil,
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.sha256 = sha256
        self.executable = executable
        self.target = target
    }
}

/// A toolchain file's own facts: the payload is the toolchain's tree as
/// setup packaged it (its `manifest.json` at the top), never a deb — the
/// importing device packages it for its own bootstrap with the same packager.
public struct TransferToolchain: Codable, Sendable, Equatable {
    /// The registered record as it was on the exporting device, without its
    /// path and installation, which are that device's.
    public var record: ToolchainRecord
    /// `ToolchainSetup.schemeVersion` of the tree.
    public var retargetScheme: Int
    /// The Apple product the tree was retargeted from.
    public var productID: String
    /// SHA-256 of Apple's package it came from: a reviewed source.
    public var sourceSHA256: String
    /// `roothide` or `rootless`, and the package architecture, of the
    /// exporting device: what it was installed for there.
    public var bootstrap: String
    public var architecture: String
    /// The Mach-O deployment value the retargeter wrote.
    public var minimumOS: String

    public init(
        record: ToolchainRecord,
        retargetScheme: Int,
        productID: String,
        sourceSHA256: String,
        bootstrap: String,
        architecture: String,
        minimumOS: String,
    ) {
        self.record = record
        self.retargetScheme = retargetScheme
        self.productID = productID
        self.sourceSHA256 = sourceSHA256
        self.bootstrap = bootstrap
        self.architecture = architecture
        self.minimumOS = minimumOS
    }
}

/// An SDK file's own facts: the payload is the registered tree.
public struct TransferSDK: Codable, Sendable, Equatable {
    /// The record as it was on the exporting device, without its path.
    public var record: SDKRecord

    public init(record: SDKRecord) {
        self.record = record
    }
}

/// A project file's own facts: the payload is the project folder, the
/// repository's history with it when it has one.
public struct TransferProject: Codable, Sendable, Equatable {
    /// As the exporting device knew it; an import always gets a new one.
    public var projectID: String
    public var name: String
    public var templateExtensionID: String?
    public var templateID: String?
    public var templateVersion: String?
    /// The descriptions' digests when it was exported, for the reader's
    /// information only: an import records none of them as approved.
    public var descriptionDigests: DescriptionDigests?
    /// The toolchain and SDK its description binds.
    public var toolchainID: String?
    public var sdkID: String?
    /// Whether `.git` travels with it (hooks and configuration left out).
    public var includesRepository: Bool
    /// The HTTPS `origin` the repository fetched from, if it had one.
    public var remoteURL: String?
    /// Files ignored by the repository's own rules, left out.
    public var ignoredCount: Int?

    public init(
        projectID: String,
        name: String,
        templateExtensionID: String? = nil,
        templateID: String? = nil,
        templateVersion: String? = nil,
        descriptionDigests: DescriptionDigests? = nil,
        toolchainID: String? = nil,
        sdkID: String? = nil,
        includesRepository: Bool = false,
        remoteURL: String? = nil,
        ignoredCount: Int? = nil,
    ) {
        self.projectID = projectID
        self.name = name
        self.templateExtensionID = templateExtensionID
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.descriptionDigests = descriptionDigests
        self.toolchainID = toolchainID
        self.sdkID = sdkID
        self.includesRepository = includesRepository
        self.remoteURL = remoteURL
        self.ignoredCount = ignoredCount
    }
}

/// `manifest.json`, the first member of every transfer file.
public struct TransferManifest: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1
    public static let fileName = "manifest.json"
    /// Every other member's archive path starts with this.
    public static let payloadPrefix = "payload/"

    public var formatVersion: Int
    public var kind: TransferKind
    /// The toolchain's, the SDK's or the project's ID.
    public var id: String
    /// What a person calls it: `Command Line Tools 27.0`, `iPhoneOS 27.0`,
    /// the project's folder name.
    public var name: String
    /// `Apelin <version> (<build>)` of the exporting app.
    public var createdBy: String
    public var created: Date
    public var members: [TransferMember]
    public var toolchain: TransferToolchain?
    public var sdk: TransferSDK?
    public var project: TransferProject?

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        kind: TransferKind,
        id: String,
        name: String,
        createdBy: String,
        created: Date = Date(),
        members: [TransferMember] = [],
        toolchain: TransferToolchain? = nil,
        sdk: TransferSDK? = nil,
        project: TransferProject? = nil,
    ) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.id = id
        self.name = name
        self.createdBy = createdBy
        self.created = created
        self.members = members
        self.toolchain = toolchain
        self.sdk = sdk
        self.project = project
    }

    /// The payload's files together, in bytes.
    public var payloadBytes: Int64 {
        members.reduce(0) { $0 + ($1.kind == .file ? max(0, $1.size ?? 0) : 0) }
    }

    /// The manifest without its member list: what the app is shown.
    public var summary: TransferSummary {
        TransferSummary(
            formatVersion: formatVersion,
            kind: kind,
            id: id,
            name: name,
            createdBy: createdBy,
            created: created,
            fileCount: members.filter { $0.kind == .file }.count,
            payloadBytes: payloadBytes,
            toolchain: toolchain,
            sdk: sdk,
            project: project,
        )
    }
}

/// A transfer manifest as the app reads it: everything but the members.
public struct TransferSummary: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var kind: TransferKind
    public var id: String
    public var name: String
    public var createdBy: String
    public var created: Date
    public var fileCount: Int
    public var payloadBytes: Int64
    public var toolchain: TransferToolchain?
    public var sdk: TransferSDK?
    public var project: TransferProject?

    public init(
        formatVersion: Int,
        kind: TransferKind,
        id: String,
        name: String,
        createdBy: String,
        created: Date,
        fileCount: Int,
        payloadBytes: Int64,
        toolchain: TransferToolchain? = nil,
        sdk: TransferSDK? = nil,
        project: TransferProject? = nil,
    ) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.id = id
        self.name = name
        self.createdBy = createdBy
        self.created = created
        self.fileCount = fileCount
        self.payloadBytes = payloadBytes
        self.toolchain = toolchain
        self.sdk = sdk
        self.project = project
    }
}

/// Where a transfer file to read is.
public enum TransferSource: Codable, Sendable, Equatable {
    /// The file, passed as a read-only descriptor. The app's choice: what it
    /// was handed by Open in Apelin or picked in Files.
    case file(DescriptorSlot)
    /// A file in `~/Documents/wiki.qaq.apelin/inbox/`, named relative to it.
    case inbox(path: String)
    /// A file an export wrote, named relative to
    /// `~/Documents/wiki.qaq.apelin/Exports/`: `TransferExport.exportedPath`,
    /// or the export's folder (`sdk-<id>`), which holds that one file.
    case exported(path: String)
}

// MARK: Export

/// Writes a transfer file of a registered toolchain, a registered SDK or a
/// project into `~/Documents/wiki.qaq.apelin/Exports/<kind>-<id>/`, replacing
/// an earlier export of the same item.
public struct TransferExportRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.transferExport
    public var kind: TransferKind
    /// The toolchain's or SDK's ID; a project's ID or folder name.
    public var id: String
    /// `Apelin <version> (<build>)`, written into the manifest.
    public var createdBy: String?

    public init(kind: TransferKind, id: String, createdBy: String? = nil) {
        self.kind = kind
        self.id = id
        self.createdBy = createdBy
    }
}

/// An export's `result`: the file it wrote.
public struct TransferExport: Codable, Sendable, Equatable {
    /// Absolute, inside the data folder, for the app's share sheet.
    public var path: String
    /// Relative to `Exports/`, for `TransferSource.exported`.
    public var exportedPath: String
    public var fileName: String
    public var size: Int64
    public var sha256: String
    public var summary: TransferSummary

    public init(
        path: String,
        exportedPath: String,
        fileName: String,
        size: Int64,
        sha256: String,
        summary: TransferSummary,
    ) {
        self.path = path
        self.exportedPath = exportedPath
        self.fileName = fileName
        self.size = size
        self.sha256 = sha256
        self.summary = summary
    }
}

// MARK: Inspect

/// Reads a transfer file's manifest and says what importing it would do on
/// this device. Fast: the payload is not read, so its digests are checked
/// by the import, before anything is installed or registered.
public struct TransferInspectRequest: OperationRequest {
    public typealias Response = TransferInspection
    public static let operation = AppOperation.transferInspect
    public var source: TransferSource
    /// The name the file came with; its extension must be the kind's.
    public var fileName: String?

    public init(source: TransferSource, fileName: String? = nil) {
        self.source = source
        self.fileName = fileName
    }
}

public struct TransferInspection: Codable, Sendable, Equatable {
    public var summary: TransferSummary
    /// The file's size in bytes.
    public var fileSize: Int64
    /// Whether an import would start. When false, `problems` says why.
    public var importable: Bool
    /// What stops it, in sentences a user reads.
    public var problems: [String]
    /// What the user should know before importing.
    public var notes: [String]
    /// The ID of the same toolchain or SDK already registered here.
    public var existingID: String?
    /// For a project: its name if free here, else the first free one with a
    /// number after it.
    public var suggestedName: String?

    public init(
        summary: TransferSummary,
        fileSize: Int64,
        importable: Bool,
        problems: [String] = [],
        notes: [String] = [],
        existingID: String? = nil,
        suggestedName: String? = nil,
    ) {
        self.summary = summary
        self.fileSize = fileSize
        self.importable = importable
        self.problems = problems
        self.notes = notes
        self.existingID = existingID
        self.suggestedName = suggestedName
    }
}

// MARK: Import

/// Imports a transfer file: every member checked against the manifest, then
/// the kind's own path — a toolchain packaged for this bootstrap, installed
/// through the install bridge, self-tested here and registered only if it
/// passed; an SDK identified, checked and registered; a project placed in
/// `Projects/<name>/` under a new project ID, nothing approved.
public struct TransferImportRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.transferImport
    public var source: TransferSource
    public var fileName: String?
    /// The kind the caller expects; a file of another kind is refused.
    public var kind: TransferKind?
    /// A project's folder name here. Absent: its own, or the first free one
    /// with a number after it. Given and taken: refused with `conflict`.
    public var projectName: String?

    public init(
        source: TransferSource,
        fileName: String? = nil,
        kind: TransferKind? = nil,
        projectName: String? = nil,
    ) {
        self.source = source
        self.fileName = fileName
        self.kind = kind
        self.projectName = projectName
    }
}

/// A project import's `result`.
public struct TransferProjectResult: Codable, Sendable, Equatable {
    public var projectID: String
    public var name: String
    public var path: String
    /// The ID it had on the exporting device.
    public var previousProjectID: String?
    public var includesRepository: Bool

    public init(
        projectID: String,
        name: String,
        path: String,
        previousProjectID: String? = nil,
        includesRepository: Bool = false,
    ) {
        self.projectID = projectID
        self.name = name
        self.path = path
        self.previousProjectID = previousProjectID
        self.includesRepository = includesRepository
    }
}

public extension ApelinService {
    /// Starts an export; follow it with `events(of:)`. Its `result` carries
    /// `TransferExport`.
    func transferExport(kind: TransferKind, id: String, createdBy: String? = nil) async throws -> TaskHandle {
        try await send(TransferExportRequest(kind: kind, id: id, createdBy: createdBy))
    }

    func transferInspect(
        _ source: TransferSource,
        fileName: String? = nil,
        descriptors: [OwnedDescriptor] = [],
    ) async throws -> TransferInspection {
        try await send(TransferInspectRequest(source: source, fileName: fileName), descriptors: descriptors)
    }

    /// Starts an import; follow it with `events(of:)`.
    func transferImport(
        _ request: TransferImportRequest,
        descriptors: [OwnedDescriptor] = [],
    ) async throws -> TaskHandle {
        try await send(request, descriptors: descriptors)
    }
}
