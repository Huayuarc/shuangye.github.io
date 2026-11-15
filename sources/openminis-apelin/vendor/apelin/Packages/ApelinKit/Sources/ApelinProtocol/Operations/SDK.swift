// SDK manager: download from a source that keeps one SDK per branch
// (`sdk/<CanonicalName>`), import an archive or a folder, identify it from
// SDKSettings.json, check and register it.
// Served by apelin-environment (Workers/Environment; ApelinEnvironment, ApelinGit).
//
// An import is a task of kind `environment`, read with `environmentAttach`.
// Its events: `stage` {stage: fetching | extracting | inspecting |
// registering}, `progress` {stage, completed, total?, detail?}, `warning`
// {message}, and before the final `state` a `result` {sdk: SDKRecord}.

public struct SDKRecord: Codable, Sendable, Equatable {
    /// `<CanonicalName>-<sha8>`.
    public var id: String
    public var canonicalName: String
    public var version: String
    public var path: String
    /// From `Foundation.tbd`, e.g. `arm64e-ios`.
    public var targets: [String]
    public var warnings: [String]
    /// SHA-256 over the registered tree (paths, kinds, link targets and
    /// contents); `id` carries its first eight hex digits.
    public var digest: String?
    /// `swift-compiler-version` of the SDK's Swift module interfaces.
    public var swiftCompilerVersion: String?
    /// Where it came from: `repository <url>#<branch>@<commit>`, `url <url>`,
    /// `file`, or `inbox <relative path>`.
    public var origin: String?

    public init(
        id: String,
        canonicalName: String,
        version: String,
        path: String,
        targets: [String] = [],
        warnings: [String] = [],
        digest: String? = nil,
        swiftCompilerVersion: String? = nil,
        origin: String? = nil,
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.version = version
        self.path = path
        self.targets = targets
        self.warnings = warnings
        self.digest = digest
        self.swiftCompilerVersion = swiftCompilerVersion
        self.origin = origin
    }
}

/// One configured SDK source: a git repository that keeps one SDK per branch
/// under `branchPrefix`.
public struct SDKSourceStatus: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
    public var enabled: Bool
    public var branchPrefix: String
    public var note: String?
    /// The branches under `branchPrefix`, when the list was asked to read them.
    public var branches: [String]?
    /// Why the branches could not be read.
    public var problem: String?

    public init(
        name: String,
        url: String,
        enabled: Bool,
        branchPrefix: String = "sdk/",
        note: String? = nil,
        branches: [String]? = nil,
        problem: String? = nil,
    ) {
        self.name = name
        self.url = url
        self.enabled = enabled
        self.branchPrefix = branchPrefix
        self.note = note
        self.branches = branches
        self.problem = problem
    }
}

public struct SDKListRequest: OperationRequest {
    public typealias Response = SDKListResponse
    public static let operation = AppOperation.sdkList
    /// Also list the configured sources; with `readSources`, ask each
    /// enabled one for its branches (network).
    public var includeSources: Bool?
    public var readSources: Bool?

    public init(includeSources: Bool? = nil, readSources: Bool? = nil) {
        self.includeSources = includeSources
        self.readSources = readSources
    }
}

public struct SDKListResponse: Codable, Sendable, Equatable {
    public var sdks: [SDKRecord]
    public var activeTasks: [TaskHandle]
    public var sources: [SDKSourceStatus]?

    public init(sdks: [SDKRecord] = [], activeTasks: [TaskHandle] = [], sources: [SDKSourceStatus]? = nil) {
        self.sdks = sdks
        self.activeTasks = activeTasks
        self.sources = sources
    }
}

public enum SDKSource: Codable, Sendable, Equatable {
    /// A git repository and the branch holding one SDK (`sdk/iPhoneOS27.0`),
    /// fetched as a shallow clone of that branch over HTTPS.
    case repository(url: String, branch: String)
    /// An archive (zip, tar.xz, tar.zst) at an HTTPS URL.
    case url(String)
    /// An archive passed as a descriptor.
    case file(DescriptorSlot)
    /// A folder or an archive already in `~/Documents/wiki.qaq.apelin/inbox/`,
    /// named relative to it (or absolute, and inside it).
    case inbox(path: String)
}

public struct SDKImportRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.sdkImport
    public var source: SDKSource
    public init(source: SDKSource) {
        self.source = source
    }
}

public struct SDKRemoveRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.sdkRemove
    public var id: String
    public init(id: String) {
        self.id = id
    }
}

public extension ApelinService {
    func sdkList(includeSources: Bool = false, readSources: Bool = false) async throws -> SDKListResponse {
        try await send(SDKListRequest(
            includeSources: includeSources ? true : nil,
            readSources: readSources ? true : nil,
        ))
    }

    /// Starts an import; follow it with `events(of:)`.
    func sdkImport(_ source: SDKSource, descriptors: [OwnedDescriptor] = []) async throws -> TaskHandle {
        try await send(SDKImportRequest(source: source), descriptors: descriptors)
    }

    func sdkRemove(id: String) async throws {
        _ = try await send(SDKRemoveRequest(id: id))
    }
}
