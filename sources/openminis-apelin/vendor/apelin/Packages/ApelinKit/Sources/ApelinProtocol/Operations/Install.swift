import ApelinCore
import Foundation

// Install: the session host copies the approved artifact to private staging,
// checks its digest and hands it to irisind by descriptor; removal only of
// packages this bridge installed, which `installationList` lists; respring
// through irisind.
// Served by the session host (Apelind/Dispatch/InstallHandler.swift).
//
// An install is a task of kind `install`, read with `buildAttach`. Its events:
// `stage` {stage: staging|submitted|following|recorded}, `irisin` (one per
// irisind event: {seq, kind, text, phase?, step?, package?, version?,
// done?, total?, exit?, problem?}), `result` (an InstallResult) and the final
// `state`. An install irisind refused also has a `conflict` (an
// InstallConflict) for each installed package in its way, before the final
// `state`. A removal is the same, kind `install`, ending in a `removed`
// {installationID, packageID, transactionID} event.
//
// `artifactID` names either
// - a build artifact: the ID a build's `artifact` event carried, which the
//   host recorded from the build worker itself (its path, digest, package ID,
//   project and build); or
// - `file:<path>`, from the app only: a `.deb` inside
//   `~/Documents/wiki.qaq.apelin/` (the path relative to that folder), which
//   the user picked.

public struct InstallResult: Codable, Sendable, Equatable {
    public var installationID: String
    /// irisind's transaction ID: a lowercase UUID the host chose.
    public var transactionID: String
    public var packageID: String
    public var version: String
    public var artifactDigest: String
    public var projectID: String?
    public var buildID: String?

    public init(
        installationID: String,
        transactionID: String,
        packageID: String,
        version: String,
        artifactDigest: String = "",
        projectID: String? = nil,
        buildID: String? = nil,
    ) {
        self.installationID = installationID
        self.transactionID = transactionID
        self.packageID = packageID
        self.version = version
        self.artifactDigest = artifactDigest
        self.projectID = projectID
        self.buildID = buildID
    }
}

/// An installed package in the way of an install irisind refused, as the
/// host found it in the package database afterwards: irisind decided, and
/// this only says who and what to do.
public struct InstallConflict: Codable, Sendable, Hashable {
    public enum Relation: String, Codable, Sendable {
        /// It already lists a path this package installs.
        case file
        /// This package's `Conflicts` names it.
        case conflicts
        /// This package's `Breaks` names it.
        case breaks
    }

    public var relation: Relation
    /// For `file`: the first such path, as dpkg lists it.
    public var file: String?
    public var packageID: String
    /// The version installed now.
    public var version: String
    /// The installation `removePackage` takes, when Apelin installed this
    /// version; nil when Apelin did not.
    public var installationID: String?
    public var projectID: String?

    public init(
        relation: Relation,
        file: String? = nil,
        packageID: String,
        version: String,
        installationID: String? = nil,
        projectID: String? = nil,
    ) {
        self.relation = relation
        self.file = file
        self.packageID = packageID
        self.version = version
        self.installationID = installationID
        self.projectID = projectID
    }
}

public struct InstallPackageRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.installPackage
    public var artifactID: String
    /// SHA-256 of the deb, lowercase hex (a `sha256:` prefix is accepted).
    /// Must match what the host stages, and the build's own record.
    public var digest: String

    public init(artifactID: String, digest: String) {
        self.artifactID = artifactID
        self.digest = digest
    }
}

public struct RemovePackageRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.removePackage
    public var installationID: String
    public init(installationID: String) {
        self.installationID = installationID
    }
}

/// The packages this bridge installed that are still on the device: per
/// package, its newest installation record — the one a removal acts on,
/// any older one being superseded —, newest first. The records are root's;
/// this is how a conversation finds an installation it did not make.
public struct InstallationListRequest: OperationRequest {
    public typealias Response = InstallationListResponse
    public static let operation = AppOperation.installationList
    /// Only this package.
    public var packageID: String?
    /// Only what this project's builds installed.
    public var projectID: String?

    public init(packageID: String? = nil, projectID: String? = nil) {
        self.packageID = packageID
        self.projectID = projectID
    }
}

public struct InstallationSummary: Codable, Sendable, Equatable {
    public var installationID: String
    public var packageID: String
    public var version: String
    /// The project and build whose artifact it was; nil for a file the app
    /// installed and for a toolchain.
    public var projectID: String?
    public var buildID: String?
    /// When irisind reported the install finished.
    public var installedAt: Date
    /// Whether `removePackage` from this caller would act on it. An agent's
    /// removal still asks under Confirm.
    public var removable: Bool
    /// Why it would not, in the words of that refusal.
    public var reason: String?

    public init(
        installationID: String,
        packageID: String,
        version: String,
        projectID: String? = nil,
        buildID: String? = nil,
        installedAt: Date,
        removable: Bool,
        reason: String? = nil,
    ) {
        self.installationID = installationID
        self.packageID = packageID
        self.version = version
        self.projectID = projectID
        self.buildID = buildID
        self.installedAt = installedAt
        self.removable = removable
        self.reason = reason
    }
}

public struct InstallationListResponse: Codable, Sendable, Equatable {
    public var installations: [InstallationSummary]

    public init(installations: [InstallationSummary]) {
        self.installations = installations
    }
}

public struct RespringRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.respring
    public init() {}
}

// MARK: Approval digests

/// The two descriptions Confirm mode binds build and install approvals to
/// (Documents/Schemas/README.md ▸ Build description, Packaging description).
public enum ApprovalDescriptionKind: String, Codable, Sendable, CaseIterable {
    case build
    case packaging
}

/// Where a description digest stands against the host's private ledger.
public enum ApprovalBaseline: String, Codable, Sendable {
    /// The template's own digest, recorded at `projectCreate`.
    case matchesTemplate
    /// Differs from the template; the user approved this digest before.
    case approved
    /// Differs and was never approved: the first run after the change asks.
    case changed
}

/// The agent's read of the ledger: is this digest the template's, approved,
/// or new? The ledger is the host's alone; there is no operation that writes
/// it. The host records an approval when it relays the user's decision, and
/// enforces the same rule itself on every build and install the agent asks
/// for.
public struct ApprovalDigestStateRequest: OperationRequest {
    public typealias Response = ApprovalDigestStateResponse
    public static let operation = AppOperation.approvalDigestState
    public var projectID: String
    public var kind: ApprovalDescriptionKind
    /// `sha256:<hex>`, as the agent computed it from the project.
    public var digest: String

    public init(projectID: String, kind: ApprovalDescriptionKind, digest: String) {
        self.projectID = projectID
        self.kind = kind
        self.digest = digest
    }
}

public struct ApprovalDigestStateResponse: Codable, Sendable, Equatable {
    public var baseline: ApprovalBaseline
    /// The template's digest, if the host recorded one for the project.
    public var templateDigest: String?
    /// The digest approved last, to diff against.
    public var lastApprovedDigest: String?

    public init(baseline: ApprovalBaseline, templateDigest: String?, lastApprovedDigest: String?) {
        self.baseline = baseline
        self.templateDigest = templateDigest
        self.lastApprovedDigest = lastApprovedDigest
    }
}

public extension ApelinService {
    /// Starts an install; follow it with `events(of:)`.
    func installPackage(artifactID: String, digest: String) async throws -> TaskHandle {
        try await send(InstallPackageRequest(artifactID: artifactID, digest: digest))
    }

    func removePackage(installationID: String) async throws -> TaskHandle {
        try await send(RemovePackageRequest(installationID: installationID))
    }

    func installationList(packageID: String? = nil, projectID: String? = nil) async throws -> InstallationListResponse {
        try await send(InstallationListRequest(packageID: packageID, projectID: projectID))
    }

    func respring() async throws {
        _ = try await send(RespringRequest())
    }

    func approvalDigestState(
        projectID: String,
        kind: ApprovalDescriptionKind,
        digest: String,
    ) async throws -> ApprovalDigestStateResponse {
        try await send(ApprovalDigestStateRequest(projectID: projectID, kind: kind, digest: digest))
    }
}
