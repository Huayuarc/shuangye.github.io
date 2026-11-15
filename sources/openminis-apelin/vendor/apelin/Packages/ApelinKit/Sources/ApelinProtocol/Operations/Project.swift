import ApelinCore

// Development extensions, templates, projects under
// ~/Documents/wiki.qaq.apelin/Projects/<name>/ and their checks.
// Served by apelin-build (Workers/Build; ApelinProject).

public enum DevelopmentExtensionKind: String, Codable, Sendable {
    case workspace
    case app
    case tweak
    case commandLineTool
    case preferenceBundle
}

public struct TemplateSummary: Codable, Sendable, Equatable {
    /// `<extension-id>/<template-id>`.
    public var id: String
    public var displayName: String
    public var summary: String?
    /// Total bytes of the template's source files before substitution.
    public var byteCount: Int64?
    /// Parameter names and descriptions the template asks for.
    public var parameters: [TemplateParameter]

    public init(
        id: String,
        displayName: String,
        summary: String? = nil,
        byteCount: Int64? = nil,
        parameters: [TemplateParameter] = [],
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.byteCount = byteCount
        self.parameters = parameters
    }
}

public struct TemplateParameter: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var summary: String?
    public var defaultValue: JSONValue?

    public init(name: String, kind: String, summary: String? = nil, defaultValue: JSONValue? = nil) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.defaultValue = defaultValue
    }
}

public struct DevelopmentExtension: Codable, Sendable, Equatable {
    public var id: String
    public var version: String
    public var kind: DevelopmentExtensionKind
    public var displayName: String
    public var templates: [TemplateSummary]
    /// Why the extension is isolated (bad manifest, duplicate ID, …), if it is.
    public var problems: [String]

    public init(
        id: String,
        version: String,
        kind: DevelopmentExtensionKind,
        displayName: String,
        templates: [TemplateSummary] = [],
        problems: [String] = [],
    ) {
        self.id = id
        self.version = version
        self.kind = kind
        self.displayName = displayName
        self.templates = templates
        self.problems = problems
    }
}

public struct ExtensionListRequest: OperationRequest {
    public typealias Response = ExtensionListResponse
    public static let operation = AppOperation.extensionList
    public init() {}
}

public struct ExtensionListResponse: Codable, Sendable, Equatable {
    public var extensions: [DevelopmentExtension]
    public init(extensions: [DevelopmentExtension] = []) {
        self.extensions = extensions
    }
}

public struct ProjectCreateRequest: OperationRequest {
    public typealias Response = ProjectCreateResponse
    public static let operation = AppOperation.projectCreate
    public var templateID: String
    /// The directory name under `Projects/`; `ProjectName` rules apply.
    public var name: String
    public var values: [String: JSONValue]
    /// A generated placeholder may be named once from the first user intent.
    public var automaticallyName: Bool?

    public init(templateID: String, name: String, values: [String: JSONValue] = [:], automaticallyName: Bool? = nil) {
        self.templateID = templateID
        self.name = name
        self.values = values
        self.automaticallyName = automaticallyName
    }
}

public struct ProjectRenameRequest: OperationRequest {
    public typealias Response = ProjectRenameResponse
    public static let operation = AppOperation.projectRename
    public var projectID: String
    public var displayName: String
    public var onlyIfAutomatic: Bool

    public init(projectID: String, displayName: String, onlyIfAutomatic: Bool = false) {
        self.projectID = projectID
        self.displayName = displayName
        self.onlyIfAutomatic = onlyIfAutomatic
    }
}

public struct ProjectRenameResponse: Codable, Sendable, Equatable {
    public var projectID: String
    public var displayName: String
    public var changed: Bool

    public init(projectID: String, displayName: String, changed: Bool) {
        self.projectID = projectID
        self.displayName = displayName
        self.changed = changed
    }
}

/// A project deleted for good: its folder under `Projects/` with every file
/// in it, once the session host has closed its conversations' sessions.
/// The app takes its conversations away when it sees the folder gone. A
/// temporary chat's folder is no project and is never deleted so.
public struct ProjectDeleteRequest: OperationRequest {
    public typealias Response = ProjectDeleteResponse
    public static let operation = AppOperation.projectDelete
    public var projectID: String
    /// Its folder under `Projects/`, when the caller names it: the project
    /// is deleted only if that folder holds it. The host forwards the
    /// folder it resolved.
    public var projectName: String?

    public init(projectID: String, projectName: String? = nil) {
        self.projectID = projectID
        self.projectName = projectName
    }
}

public struct ProjectDeleteResponse: Codable, Sendable, Equatable {
    public var projectID: String
    /// The folder that went.
    public var projectName: String

    public init(projectID: String, projectName: String) {
        self.projectID = projectID
        self.projectName = projectName
    }
}

public struct ProjectCreateResponse: Codable, Sendable, Equatable {
    public var projectID: String
    public var name: String
    public var path: String
    /// The Confirm baseline of the project exactly as the template made it.
    /// The session host stores it in its private state, bound to
    /// `projectID`; the project folder never holds it.
    public var baseline: ProjectBaseline?
    /// The two digests alone, which the host's approval ledger records as
    /// the template baseline (the same values as `baseline`).
    public var descriptionDigests: DescriptionDigests?

    public init(
        projectID: String,
        name: String,
        path: String,
        baseline: ProjectBaseline? = nil,
        descriptionDigests: DescriptionDigests? = nil,
    ) {
        self.projectID = projectID
        self.name = name
        self.path = path
        self.baseline = baseline
        self.descriptionDigests = descriptionDigests
            ?? baseline.map { DescriptionDigests(build: $0.build.digest, packaging: $0.packaging.digest) }
    }
}

/// The build and packaging description digests of a project as it is now
/// (Documents/Schemas/README.md ▸ Approval digests), `sha256:…` each.
public struct DescriptionDigests: Codable, Sendable, Equatable {
    public var build: String
    public var packaging: String

    public init(build: String, packaging: String) {
        self.build = build
        self.packaging = packaging
    }
}

/// What Confirm mode compares a later build or install against
/// (Documents/Schemas/README.md ▸ Approval digests): both descriptions'
/// canonical JSON and digests, and the template they came from. Made by
/// apelin-build at `projectCreate`; kept by the host, never by a worker.
public struct ProjectBaseline: Codable, Sendable, Equatable {
    public struct Description: Codable, Sendable, Equatable {
        public var canonical: String
        public var digest: String

        public init(canonical: String, digest: String) {
            self.canonical = canonical
            self.digest = digest
        }
    }

    public var projectID: String
    public var templateExtensionID: String
    public var templateID: String
    public var templateVersion: String
    public var templateDigest: String
    public var build: Description
    public var packaging: Description

    public init(
        projectID: String,
        templateExtensionID: String,
        templateID: String,
        templateVersion: String,
        templateDigest: String,
        build: Description,
        packaging: Description,
    ) {
        self.projectID = projectID
        self.templateExtensionID = templateExtensionID
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.templateDigest = templateDigest
        self.build = build
        self.packaging = packaging
    }
}

public enum DiagnosticSeverity: String, Codable, Sendable {
    case error
    case warning
    case note
}

public struct ProjectDiagnostic: Codable, Sendable, Equatable {
    public var code: String
    public var severity: DiagnosticSeverity
    public var message: String
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var field: String?
    /// Names of fix actions the UI or the agent may offer.
    public var fixes: [String]

    public init(
        code: String,
        severity: DiagnosticSeverity,
        message: String,
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        field: String? = nil,
        fixes: [String] = [],
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.column = column
        self.field = field
        self.fixes = fixes
    }
}

/// What a check is for beyond building.
public enum ProjectCheckPurpose: String, Codable, Sendable, CaseIterable {
    /// Also warn about what a package for other people should not carry:
    /// metadata still the template's, local identifiers, no app icon, a
    /// version already packaged for the target. Warnings only (`distribution.*`
    /// codes); the build is never refused for them.
    case distribution
}

/// A registered component a project binds: `apelin-project.json` ▸
/// `environment.toolchain` or `environment.sdk`.
public struct ProjectComponentBinding: Codable, Sendable, Equatable {
    public var id: String
    /// `sha256:…`, the registry's, never a caller's.
    public var digest: String

    public init(id: String, digest: String) {
        self.id = id
        self.digest = digest
    }
}

/// The toolchain and SDK a project is bound to.
public struct ProjectEnvironmentBinding: Codable, Sendable, Equatable {
    public var toolchain: ProjectComponentBinding
    public var sdk: ProjectComponentBinding

    public init(toolchain: ProjectComponentBinding, sdk: ProjectComponentBinding) {
        self.toolchain = toolchain
        self.sdk = sdk
    }
}

/// Registered components to check a project against in place of the ones
/// it binds; a nil one keeps the project's. Nothing is written: the check
/// answers the binding it ran with, its digests the registry's.
public struct ProjectEnvironmentChoice: Codable, Sendable, Equatable {
    public var toolchainID: String?
    public var sdkID: String?

    public init(toolchainID: String? = nil, sdkID: String? = nil) {
        self.toolchainID = toolchainID
        self.sdkID = sdkID
    }
}

public struct ProjectCheckRequest: OperationRequest {
    public typealias Response = ProjectCheckResponse
    public static let operation = AppOperation.projectCheck
    public var projectID: String
    public var purpose: ProjectCheckPurpose?
    /// The distribution target, for the already-packaged check; absent, any.
    public var bootstrap: BuildBootstrap?
    /// Check as if the project were bound to these registered components,
    /// before it is switched to them; one that is not registered is
    /// `notFound`. Absent: the binding the project has.
    public var environment: ProjectEnvironmentChoice?

    public init(
        projectID: String,
        purpose: ProjectCheckPurpose? = nil,
        bootstrap: BuildBootstrap? = nil,
        environment: ProjectEnvironmentChoice? = nil,
    ) {
        self.projectID = projectID
        self.purpose = purpose
        self.bootstrap = bootstrap
        self.environment = environment
    }
}

public struct ProjectCheckResponse: Codable, Sendable, Equatable {
    public var passed: Bool
    public var diagnostics: [ProjectDiagnostic]
    /// Absent when a description could not be computed (a referenced file
    /// missing or outside the project): the host treats that as a change.
    public var descriptionDigests: DescriptionDigests?
    /// The binding the check ran with: the project's own, or the request's
    /// `environment` resolved in the registry. Absent when the project file
    /// did not read.
    public var environment: ProjectEnvironmentBinding?
    /// `external` for a workspace, which builds with its own script (its
    /// `external` declaration) and has no description digests; absent for a
    /// project apelin-build builds from its description.
    public var buildSystem: BuildSystemKind?

    public init(
        passed: Bool,
        diagnostics: [ProjectDiagnostic] = [],
        descriptionDigests: DescriptionDigests? = nil,
        environment: ProjectEnvironmentBinding? = nil,
        buildSystem: BuildSystemKind? = nil,
    ) {
        self.passed = passed
        self.diagnostics = diagnostics
        self.descriptionDigests = descriptionDigests
        self.environment = environment
        self.buildSystem = buildSystem
    }
}

/// Who builds a project: apelin-build from its description, or the
/// workspace's own script.
public enum BuildSystemKind: String, Codable, Sendable {
    case apelin
    case external
}

public extension ApelinService {
    func extensionList() async throws -> ExtensionListResponse {
        try await send(ExtensionListRequest())
    }

    func projectCreate(_ request: ProjectCreateRequest) async throws -> ProjectCreateResponse {
        try await send(request)
    }

    func projectCheck(
        projectID: String,
        purpose: ProjectCheckPurpose? = nil,
        bootstrap: BuildBootstrap? = nil,
        environment: ProjectEnvironmentChoice? = nil,
    ) async throws -> ProjectCheckResponse {
        try await send(ProjectCheckRequest(
            projectID: projectID,
            purpose: purpose,
            bootstrap: bootstrap,
            environment: environment,
        ))
    }

    func projectRename(_ request: ProjectRenameRequest) async throws -> ProjectRenameResponse {
        try await send(request)
    }

    func projectDelete(_ request: ProjectDeleteRequest) async throws -> ProjectDeleteResponse {
        try await send(request)
    }
}
