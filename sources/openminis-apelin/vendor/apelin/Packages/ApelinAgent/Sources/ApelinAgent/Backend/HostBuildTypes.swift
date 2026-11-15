import Foundation

// MARK: - build

public enum BuildConfiguration: String, Sendable, Hashable, Codable, CaseIterable {
    case debug
    case release
}

public struct BuildRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var configuration: BuildConfiguration
    /// The build-description digest the approval was bound to. The host
    /// recomputes it and refuses the build if the description changed since.
    public var buildDescriptionDigest: String
    public var bootstrap: String?

    public init(
        context: HostCallContext,
        configuration: BuildConfiguration,
        buildDescriptionDigest: String,
        bootstrap: String? = nil,
    ) {
        self.context = context
        self.configuration = configuration
        self.buildDescriptionDigest = buildDescriptionDigest
        self.bootstrap = bootstrap
    }
}

public struct BuildDiagnostic: Sendable, Hashable, Codable {
    public enum Severity: String, Sendable, Hashable, Codable { case error, warning, note }
    public var severity: Severity
    /// Relative to the project root.
    public var file: String?
    public var line: Int?
    public var column: Int?
    /// The member of `file` a check found wrong, as a JSON pointer such as
    /// `/configurations/Debug/linkFlags`.
    public var field: String?
    public var message: String

    public init(
        severity: Severity,
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        field: String? = nil,
        message: String,
    ) {
        self.severity = severity
        self.file = file
        self.line = line
        self.column = column
        self.field = field
        self.message = message
    }
}

public struct BuildArtifact: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case package, dylib, executable, bundle, dSYM }
    public var id: String
    public var kind: Kind
    public var name: String
    /// SHA-256 of the artifact, hex.
    public var digest: String

    public init(id: String, kind: Kind, name: String, digest: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.digest = digest
    }
}

public struct BuildResponse: Sendable, Hashable, Codable {
    public var buildID: String
    public var succeeded: Bool
    public var diagnostics: [BuildDiagnostic]
    public var artifacts: [BuildArtifact]
    /// The tail of the build log, bounded by the host.
    public var logExcerpt: String
    /// After a Debug build while nothing the project built is installed,
    /// the identifiers Apelin made up for it (`PlaceholderIdentifiers`);
    /// the agent adds it, the host never does.
    public var identifierHint: String?

    public init(
        buildID: String,
        succeeded: Bool,
        diagnostics: [BuildDiagnostic] = [],
        artifacts: [BuildArtifact] = [],
        logExcerpt: String = "",
    ) {
        self.buildID = buildID
        self.succeeded = succeeded
        self.diagnostics = diagnostics
        self.artifacts = artifacts
        self.logExcerpt = logExcerpt
    }
}

// MARK: - Distribution

public struct DistributionCheckRequest: Sendable, Hashable, Codable {
    public var project: ProjectIdentity
    /// `roothide` or `rootless`; nil compares the version with both.
    public var bootstrap: String?
    public init(project: ProjectIdentity, bootstrap: String? = nil) {
        self.project = project
        self.bootstrap = bootstrap
    }
}

public struct DistributionCheckResponse: Sendable, Hashable, Codable {
    /// Nothing left to change before packaging for other people: no error
    /// that stops the build, and no warning about what the package carries.
    public var ready: Bool
    /// Each names the field or file to change.
    public var issues: [BuildDiagnostic]
    /// What this check could not look at yet, such as a workspace's package,
    /// which its release build checks.
    public var note: String?
    public init(ready: Bool, issues: [BuildDiagnostic] = [], note: String? = nil) {
        self.ready = ready
        self.issues = issues
        self.note = note
    }
}
