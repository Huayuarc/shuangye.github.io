import struct ApelinProtocol.InstallConflict
import Foundation

// MARK: - install / apelin_package_remove / apelin_package_list / respring

public struct InstallRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var artifactID: String
    /// The host copies the artifact to private staging and checks this
    /// digest before it reaches the installer.
    public var artifactDigest: String
    /// The packaging-description digest the approval was bound to.
    public var packagingDescriptionDigest: String

    public init(
        context: HostCallContext,
        artifactID: String,
        artifactDigest: String,
        packagingDescriptionDigest: String,
    ) {
        self.context = context
        self.artifactID = artifactID
        self.artifactDigest = artifactDigest
        self.packagingDescriptionDigest = packagingDescriptionDigest
    }
}

public struct InstallResponse: Sendable, Hashable, Codable {
    public var transactionID: String
    public var installationID: String?
    public var packageID: String
    public var version: String
    public var succeeded: Bool
    public var message: String
    /// When the installer refused it: each installed package in the way,
    /// with the `installationID` apelin_package_remove takes when Apelin
    /// installed it. nil when none was found.
    public var conflicts: [InstallConflict]?
    /// For an app project, that a copy already running keeps the previous
    /// build and how to restart it (`AppRelaunch`); the agent adds it, the
    /// host never does.
    public var relaunchHint: String?

    public init(
        transactionID: String,
        installationID: String?,
        packageID: String,
        version: String,
        succeeded: Bool,
        message: String = "",
        conflicts: [InstallConflict]? = nil,
        relaunchHint: String? = nil,
    ) {
        self.transactionID = transactionID
        self.installationID = installationID
        self.packageID = packageID
        self.version = version
        self.succeeded = succeeded
        self.message = message
        self.conflicts = conflicts
        self.relaunchHint = relaunchHint
    }
}

public struct RemovePackageRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// A host-registered installation record; the host resolves the package.
    public var installationID: String

    public init(context: HostCallContext, installationID: String) {
        self.context = context
        self.installationID = installationID
    }
}

public struct RemovePackageResponse: Sendable, Hashable, Codable {
    public var transactionID: String
    public var succeeded: Bool
    /// Why a removal was refused (unmanaged, replaced externally, …).
    public var message: String

    public init(transactionID: String, succeeded: Bool, message: String = "") {
        self.transactionID = transactionID
        self.succeeded = succeeded
        self.message = message
    }
}

// MARK: - apelin_package_list

public struct InstallationListToolRequest: Sendable, Hashable, Codable {
    /// Only this package.
    public var packageID: String?
    /// Only what this project's builds installed.
    public var projectID: String?

    public init(packageID: String? = nil, projectID: String? = nil) {
        self.packageID = packageID
        self.projectID = projectID
    }
}

public struct InstallationListToolResponse: Sendable, Hashable, Codable {
    /// Newest first: per package still installed, the installation a
    /// removal acts on.
    public var installations: [ListedInstallation]
    /// More installations than the list holds.
    public var truncated: Bool

    public init(installations: [ListedInstallation], truncated: Bool = false) {
        self.installations = installations
        self.truncated = truncated
    }
}

public struct ListedInstallation: Sendable, Hashable, Codable {
    /// What apelin_package_remove takes.
    public var installationID: String
    public var packageID: String
    public var version: String
    /// The project whose build it was, and its folder while it is under
    /// `Projects/`.
    public var projectID: String?
    public var project: String?
    public var buildID: String?
    public var installedAt: Date
    /// Whether apelin_package_remove can remove it; it still asks in Strict mode.
    public var removable: Bool
    /// Why not, when it cannot.
    public var reason: String?

    public init(
        installationID: String,
        packageID: String,
        version: String,
        projectID: String? = nil,
        project: String? = nil,
        buildID: String? = nil,
        installedAt: Date,
        removable: Bool,
        reason: String? = nil,
    ) {
        self.installationID = installationID
        self.packageID = packageID
        self.version = version
        self.projectID = projectID
        self.project = project
        self.buildID = buildID
        self.installedAt = installedAt
        self.removable = removable
        self.reason = reason
    }
}

public struct RespringRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public init(context: HostCallContext) {
        self.context = context
    }
}

public struct RespringResponse: Sendable, Hashable, Codable {
    public var succeeded: Bool
    /// What the app needs to reconnect afterwards.
    public var reconnectHint: String?

    public init(succeeded: Bool, reconnectHint: String? = nil) {
        self.succeeded = succeeded
        self.reconnectHint = reconnectHint
    }
}
