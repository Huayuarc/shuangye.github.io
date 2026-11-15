import Foundation

// MARK: - apelin_package_publish

/// What apelin_package_publish reads before anyone is asked: the package
/// repository Settings ▸ Git ▸ Publishing linked, whether the user is signed
/// in to GitHub, and what each build recorded of its package.
public struct PackagePublicationRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// Builds by their ID, which is also their package artifact's.
    public var buildIDs: [String]
    public init(context: HostCallContext, buildIDs: [String]) {
        self.context = context
        self.buildIDs = buildIDs
    }
}

public struct PackagePublication: Sendable, Hashable, Codable {
    public struct Repository: Sendable, Hashable, Codable {
        /// `owner/name`.
        public var fullName: String
        /// The address a package manager adds.
        public var sourceURL: String?
        public init(fullName: String, sourceURL: String?) {
            self.fullName = fullName
            self.sourceURL = sourceURL
        }
    }

    /// Nil when none is linked, or its project is gone.
    public var repository: Repository?
    /// Whether a github.com sign-in is saved; nil when it could not be read.
    public var signedIn: Bool?
    /// One for each build asked about, in order; nil for a build that left
    /// no package record.
    public var builds: [PackageBuildRecord?]
    public init(repository: Repository?, signedIn: Bool?, builds: [PackageBuildRecord?]) {
        self.repository = repository
        self.signedIn = signedIn
        self.builds = builds
    }
}

/// A build's package as its artifact record names it.
public struct PackageBuildRecord: Sendable, Hashable, Codable {
    public var buildID: String
    public var projectID: String
    /// `Debug` or `Release`, the project's configuration names, as the
    /// artifact record spells them (ApelinProject's `ConfigurationName`).
    public var configuration: String
    /// `roothide` or `rootless`.
    public var bootstrap: String
    public var packageID: String
    public var version: String
    public var architecture: String
    /// The `.deb`, where the build wrote it.
    public var file: String
    /// `sha256:<hex>` of the `.deb` as the build wrote it.
    public var digest: String
    /// Whether the `.deb` is still a regular file there.
    public var present: Bool
    public init(
        buildID: String,
        projectID: String,
        configuration: String,
        bootstrap: String,
        packageID: String,
        version: String,
        architecture: String,
        file: String,
        digest: String,
        present: Bool,
    ) {
        self.buildID = buildID
        self.projectID = projectID
        self.configuration = configuration
        self.bootstrap = bootstrap
        self.packageID = packageID
        self.version = version
        self.architecture = architecture
        self.file = file
        self.digest = digest
        self.present = present
    }
}

/// The packages apelin_package_publish's card named, published together:
/// their files and digests to the repository it named, nothing else.
public struct PackagePublishToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var publication: PackagePublishApproval
    public init(context: HostCallContext, publication: PackagePublishApproval) {
        self.context = context
        self.publication = publication
    }
}

public struct PackagePublishToolResponse: Sendable, Hashable, Codable {
    /// `owner/name`.
    public var repository: String
    /// The address a package manager adds, which the user is given.
    public var sourceURL: String?
    /// The files added to the repository's `debs/`.
    public var published: [String]
    /// The files that were there already with the same bytes.
    public var alreadyPublished: [String]
    /// The commit that added them, when any was added.
    public var commit: String?
    /// What happens next, in words.
    public var next: String
    public init(
        repository: String,
        sourceURL: String?,
        published: [String],
        alreadyPublished: [String],
        commit: String?,
        next: String,
    ) {
        self.repository = repository
        self.sourceURL = sourceURL
        self.published = published
        self.alreadyPublished = alreadyPublished
        self.commit = commit
        self.next = next
    }
}

/// A publication that did not happen, in words the model can act on and
/// pass on to the user.
public struct PackagePublishToolFailure: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}
