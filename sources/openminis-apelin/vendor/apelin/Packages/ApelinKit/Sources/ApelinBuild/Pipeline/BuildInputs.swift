import ApelinCore
import ApelinProject
import ApelinProtocol
import Foundation

/// Which layout this device's bootstrap is (`BuildBootstrap.resolve`, the
/// rule the agent's system prompt reads too), as the project document
/// spells it.
public enum BootstrapResolution {
    public static func bootstrap(installRoot: String, home: String) -> Bootstrap {
        switch BuildBootstrap.resolve(installRoot: installRoot, home: home) {
        case .roothide: .roothide
        case .rootless: .rootless
        }
    }
}

/// Everything one build needs, resolved before the first tool runs.
public struct BuildInputs: Sendable {
    /// Unique per build; `APELIN_BUILD_ID`, the marker `apelin_package_confirm_loaded`
    /// matches, and the artifact's ID. The session host's task ID.
    public var buildID: String
    public var projectRoot: URL
    public var project: ProjectDocument
    public var configuration: ConfigurationName
    public var bootstrap: Bootstrap
    public var toolchain: RegisteredToolchain
    public var sdk: RegisteredSDK
    public var catalog: ExtensionCatalog
    /// `Builds/<projectID>/<buildID>/`, outside the project.
    public var workDirectory: URL
    /// The install root `hello` answered, for script interpreters and the
    /// paths the installed package will have.
    public var installRoot: String
    /// HOME for the tools.
    public var home: String
    /// Seconds since 1970 for every archive member: the build's start.
    public var timestamp: Int64
    /// `sha256:` of each file the checked build and packaging descriptions
    /// name, as the check read it; nil before a check. A file the build reads
    /// again must still be those bytes, so the artifact's digests describe
    /// what it was built and packaged from.
    public var checkedFiles: [String: String]?
    /// The build digest the session host approved under Confirm; the check
    /// must find this one, or the build stops before any step runs.
    public var approvedBuildDigest: String?

    public init(
        buildID: String,
        projectRoot: URL,
        project: ProjectDocument,
        configuration: ConfigurationName,
        bootstrap: Bootstrap,
        toolchain: RegisteredToolchain,
        sdk: RegisteredSDK,
        catalog: ExtensionCatalog,
        workDirectory: URL,
        installRoot: String,
        home: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
    ) {
        self.buildID = buildID
        self.projectRoot = projectRoot
        self.project = project
        self.configuration = configuration
        self.bootstrap = bootstrap
        self.toolchain = toolchain
        self.sdk = sdk
        self.catalog = catalog
        self.workDirectory = workDirectory
        self.installRoot = installRoot
        self.home = home
        self.timestamp = timestamp
    }

    /// A project file the descriptions name, refused unless it is the bytes
    /// the check digested.
    func readChecked(_ path: String) throws -> Data {
        let data = try ProjectFiles.read(path, in: projectRoot)
        if let checkedFiles, checkedFiles[path] != CanonicalJSON.sha256Tag(data) {
            throw BuildFailure("\(path) changed after the project check; build again")
        }
        return data
    }

    /// Resolves a project for one build: the project by ID, its toolchain
    /// and SDK by the IDs it is bound to (and the digests it bound), the
    /// bootstrap this device is.
    public static func resolve(
        buildID: String,
        projectID: String,
        configuration: ConfigurationName,
        store: ProjectStore,
        catalog: ExtensionCatalog,
        registry: EnvironmentRegistry,
        installRoot: String,
        home: String,
        bootstrap: Bootstrap? = nil,
    ) throws -> BuildInputs {
        let located = try store.locate(projectID)
        let project = located.project
        guard let toolchain = try registry.toolchain(project.environment.toolchain.id) else {
            throw ApelinError(.notFound, "toolchain \(project.environment.toolchain.id) is not registered")
        }
        guard toolchain.digest == project.environment.toolchain.digest else {
            throw ApelinError(
                .conflict,
                "toolchain \(toolchain.id) was registered again with other contents; rebind the project",
            )
        }
        guard let sdk = try registry.sdk(project.environment.sdk.id) else {
            throw ApelinError(.notFound, "SDK \(project.environment.sdk.id) is not registered")
        }
        guard sdk.digest == project.environment.sdk.digest else {
            throw ApelinError(.conflict, "SDK \(sdk.id) was registered again with other contents; rebind the project")
        }
        let target = bootstrap ?? BootstrapResolution.bootstrap(installRoot: installRoot, home: home)
        guard project.architectures[target] != nil else {
            throw ApelinError(
                .badRequest,
                "the project does not build for \(target.rawValue), which was requested; add \(target.rawValue) to the project's architectures",
            )
        }
        let work = store.buildsDirectory
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent(buildID, isDirectory: true)
        return BuildInputs(
            buildID: buildID,
            projectRoot: located.root,
            project: project,
            configuration: configuration,
            bootstrap: target,
            toolchain: toolchain,
            sdk: sdk,
            catalog: catalog,
            workDirectory: work,
            installRoot: installRoot,
            home: home,
        )
    }
}

/// Where a build reports as it goes. apelin-build turns these into task
/// events; a test collects them.
public protocol BuildReporter: Sendable {
    func stage(_ name: String, product: String?)
    func log(_ line: String)
    func diagnostic(_ diagnostic: ProjectDiagnostic)
}

/// What a finished build made, before packaging.
public struct BuildProducts: Codable, Sendable, Equatable {
    public struct Product: Codable, Sendable, Equatable {
        public var id: String
        public var type: ProductType
        /// The signed Mach-O, or the `.app`/`.bundle` directory.
        public var path: String
        /// The signed Mach-O itself (inside the bundle for app and bundle).
        public var executable: String
        /// SHA-256 of `executable`.
        public var digest: String
        /// Architecture → LC_UUID.
        public var uuids: [String: String]
    }

    public struct DSYM: Codable, Sendable, Equatable {
        public var product: String
        public var path: String
        public var uuids: [String: String]
    }

    public var products: [Product]
    public var dsyms: [DSYM]
    public var log: String

    public func product(_ id: String) -> Product? {
        products.first { $0.id == id }
    }
}

public struct BuildFailure: Error, CustomStringConvertible, Sendable {
    public var description: String
    public var diagnostics: [ProjectDiagnostic]

    public init(_ description: String, diagnostics: [ProjectDiagnostic] = []) {
        self.description = description
        self.diagnostics = diagnostics
    }
}
