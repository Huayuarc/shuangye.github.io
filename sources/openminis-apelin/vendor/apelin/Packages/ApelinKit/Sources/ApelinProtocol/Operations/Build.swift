// Build: compile, link, lipo, dSYM, strip, sign (last), package a deb.
// Served by apelin-build (Workers/Build; ApelinBuild); tasks in the host's registry.
//
// Events a build emits (kind → payload): `stage` {stage}, `diagnostic`
// (a ProjectDiagnostic), `log` {line}, `artifact` (a BuildArtifact),
// `state` {state}.

public enum BuildConfiguration: String, Codable, Sendable {
    case debug
    case release
}

public struct BuildArtifact: Codable, Sendable, Equatable {
    /// What `installPackage` takes.
    public var artifactID: String
    /// SHA-256 of the deb, bound into the install approval.
    public var digest: String
    public var packageID: String
    public var version: String
    public var dsymUUIDs: [String]
    /// `APELIN_BUILD_ID` of the build that made it: what `confirmLoaded` takes.
    public var buildID: String?
    /// `rootless` or `roothide`: the layout the deb was written for.
    public var bootstrap: String?
    /// The packaging description's digest at build time, for the host's
    /// Confirm decision on install (Documents/Schemas/README.md ▸ Approval digests).
    public var packagingDigest: String?
    /// The deb, absolute, inside `~/Documents/wiki.qaq.apelin/Builds/`; the
    /// host copies it to private staging and checks `digest` there.
    public var path: String?
    public var projectID: String?
    /// The regular files and links the deb installs, as dpkg lists them
    /// (`/var/jb/usr/bin/x`), fewest components first and at most
    /// `maximumPackageFiles`: what the host looks up in the package
    /// database when irisind refuses the install.
    public var packageFiles: [String]?

    public static let maximumPackageFiles = 256

    public init(
        artifactID: String,
        digest: String,
        packageID: String,
        version: String,
        dsymUUIDs: [String] = [],
        buildID: String? = nil,
        bootstrap: String? = nil,
        packagingDigest: String? = nil,
        path: String? = nil,
        projectID: String? = nil,
        packageFiles: [String]? = nil,
    ) {
        self.artifactID = artifactID
        self.digest = digest
        self.packageID = packageID
        self.version = version
        self.dsymUUIDs = dsymUUIDs
        self.buildID = buildID
        self.bootstrap = bootstrap
        self.packagingDigest = packagingDigest
        self.path = path
        self.projectID = projectID
        self.packageFiles = packageFiles
    }
}

/// What a build records for `confirmLoaded` (the build side of Milestone 1
/// §8 "respring 与确认加载"): the marker the template's constructor logs,
/// the subsystem it logs under, and where the dylib and its filter will be
/// once installed. apelin-build writes it into the artifact record
/// (`~/Documents/wiki.qaq.apelin/Builds/artifacts/<artifactID>.json`,
/// member `loadCheck`; artifactID is the build ID); the diagnostics side reads it by build ID.
public struct BuildLoadCheck: Codable, Sendable, Equatable {
    public var buildID: String
    /// `ApelinLoaded <buildID>`, which the tweak template logs from its
    /// constructor (followed by ` in <process>`).
    public var marker: String
    /// The os_log subsystem: the package ID.
    public var markerSubsystem: String
    /// `/Library/MobileSubstrate/DynamicLibraries/<name>.dylib`.
    public var dylibLogicalPath: String
    /// The same under this device's install root, as the target process
    /// sees it once installed.
    public var dylibInstalledPath: String
    public var filterPlistLogicalPath: String
    public var filterPlistInstalledPath: String
    /// The filter as built: bundle IDs, executable names, classes.
    public var bundles: [String]
    public var executables: [String]
    public var classes: [String]

    public init(
        buildID: String,
        marker: String,
        markerSubsystem: String,
        dylibLogicalPath: String,
        dylibInstalledPath: String,
        filterPlistLogicalPath: String,
        filterPlistInstalledPath: String,
        bundles: [String],
        executables: [String],
        classes: [String],
    ) {
        self.buildID = buildID
        self.marker = marker
        self.markerSubsystem = markerSubsystem
        self.dylibLogicalPath = dylibLogicalPath
        self.dylibInstalledPath = dylibInstalledPath
        self.filterPlistLogicalPath = filterPlistLogicalPath
        self.filterPlistInstalledPath = filterPlistInstalledPath
        self.bundles = bundles
        self.executables = executables
        self.classes = classes
    }

    /// The marker for a build ID.
    public static func marker(buildID: String) -> String {
        "ApelinLoaded \(buildID)"
    }
}

/// Explicit distribution target; absent on a normal build means this device's layout.
public enum BuildBootstrap: String, Codable, Sendable, CaseIterable {
    case roothide
    case rootless
}

public struct BuildStartRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.buildStart
    public var projectID: String
    public var configuration: BuildConfiguration
    public var bootstrap: BuildBootstrap?
    /// Written by the session host alone, for an agent's build under
    /// Confirm: the build digest its check approved. apelin-build refuses
    /// the build if the description it runs has another.
    public var approvedBuildDigest: String?

    public init(
        projectID: String,
        configuration: BuildConfiguration = .debug,
        bootstrap: BuildBootstrap? = nil,
        approvedBuildDigest: String? = nil,
    ) {
        self.projectID = projectID
        self.configuration = configuration
        self.bootstrap = bootstrap
        self.approvedBuildDigest = approvedBuildDigest
    }
}

/// Reads build and install tasks.
public struct BuildAttachRequest: TaskAttachRequest {
    public static let operation = AppOperation.buildAttach
    public var taskID: TaskID
    public var afterSeq: EventSeq
    public var waitMilliseconds: Int

    public init(taskID: TaskID, afterSeq: EventSeq = .start, waitMilliseconds: Int = Self.defaultWaitMilliseconds) {
        self.taskID = taskID
        self.afterSeq = afterSeq
        self.waitMilliseconds = waitMilliseconds
    }
}

public struct BuildCancelRequest: TaskCancelRequest {
    public static let operation = AppOperation.buildCancel
    public var taskID: TaskID
    public init(taskID: TaskID) {
        self.taskID = taskID
    }
}

public extension ApelinService {
    /// Starts a build; follow it with `events(of:)`.
    func buildStart(
        projectID: String,
        configuration: BuildConfiguration = .debug,
        bootstrap: BuildBootstrap? = nil,
    ) async throws -> TaskHandle {
        try await send(BuildStartRequest(projectID: projectID, configuration: configuration, bootstrap: bootstrap))
    }

    func buildAttach(_ request: BuildAttachRequest) async throws -> TaskEventBatch {
        try await send(request)
    }

    func buildCancel(taskID: TaskID) async throws {
        _ = try await send(BuildCancelRequest(taskID: taskID))
    }
}
