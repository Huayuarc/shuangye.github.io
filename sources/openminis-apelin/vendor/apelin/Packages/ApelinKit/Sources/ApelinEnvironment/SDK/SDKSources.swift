import ApelinCore
import ApelinGit
import ApelinProtocol
import Foundation

/// The SDK sources: git repositories that keep one SDK per branch, each
/// branch `sdk/<CanonicalName>` holding that one SDK's folder, so a shallow
/// clone of the branch fetches exactly one SDK (libgit2 has no partial
/// clone). The list lives in `Environment/sdk-sources.json`; there is no
/// wire operation for it, and without the file the default list stands.
///
/// The default list is `owngoal-dev/iOS-SDKs`, enabled: a detached fork of
/// `xybp888/iOS-SDKs`, credited in its README, with one branch
/// `sdk/iPhoneOS<version>` per SDK holding `iPhoneOS<version>.sdk`, named
/// for the version its own `SDKSettings.json` gives. The owner had it
/// created on 2026-10-19. A file that lists other sources, or this one
/// disabled, replaces the default.
public struct SDKSourceList: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var name: String
        public var url: String
        public var enabled: Bool
        public var branchPrefix: String
        public var note: String?

        public init(name: String, url: String, enabled: Bool, branchPrefix: String = "sdk/", note: String? = nil) {
            self.name = name
            self.url = url
            self.enabled = enabled
            self.branchPrefix = branchPrefix
            self.note = note
        }
    }

    public var sources: [Source]

    public init(sources: [Source] = []) {
        self.sources = sources
    }

    /// What ships: the known sources.
    public static let `default` = SDKSourceList(sources: knownSources)

    /// The sources Apelin knows. See the type's comment.
    public static let knownSources: [Source] = [
        Source(
            name: "OwnGoal iOS SDKs",
            url: "https://github.com/owngoal-dev/iOS-SDKs.git",
            enabled: true,
            branchPrefix: "sdk/",
            note: "Apple's iPhoneOS SDKs, one per branch, collected by xybp888/iOS-SDKs.",
        ),
    ]

    /// The configured list, or the default when the file is missing or does
    /// not read.
    public static func load(_ layout: EnvironmentLayout) -> SDKSourceList {
        ((try? JSONFile.read(SDKSourceList.self, at: layout.sdkSources)) ?? nil) ?? .default
    }

    public var hasEnabledSource: Bool {
        sources.contains(where: \.enabled)
    }

    /// Every configured source, and with `read` the branches each enabled
    /// one lists under its prefix.
    public func statuses(read: Bool) -> [SDKSourceStatus] {
        sources.map { source in
            var status = SDKSourceStatus(
                name: source.name,
                url: source.url,
                enabled: source.enabled,
                branchPrefix: source.branchPrefix,
                note: source.note,
            )
            guard read, source.enabled else { return status }
            guard GitClone.isAcceptedRemote(source.url) else {
                status.problem = "only https:// sources are read"
                return status
            }
            do {
                status.branches = try GitRemote.branches(url: source.url, prefix: source.branchPrefix)
            } catch {
                status.problem = String(describing: error)
            }
            return status
        }
    }
}

/// One SDK an enabled source offers: a branch, and the version its name
/// gives — `sdk/iPhoneOS18.5` is 18.5. What is registered is what the
/// tree's `SDKSettings.json` says, which the caller checks again after the
/// import.
public struct SDKOffer: Sendable, Equatable {
    public var source: String
    public var url: String
    public var branch: String
    public var version: String

    public init(source: String, url: String, branch: String, version: String) {
        self.source = source
        self.url = url
        self.branch = branch
        self.version = version
    }

    /// The version a branch names after its prefix: `iPhoneOS18.5` → 18.5;
    /// nil for anything but `iPhoneOS` and one to three numbers.
    public static func version(ofBranch branch: String, prefix: String) -> String? {
        guard branch.hasPrefix(prefix) else { return nil }
        let name = branch.dropFirst(prefix.count)
        guard name.lowercased().hasPrefix("iphoneos") else { return nil }
        let version = String(name.dropFirst("iphoneos".count))
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (0x30 ... 0x39).contains($0) } })
        else { return nil }
        return version
    }

    /// Every branch the enabled sources listed that names a version, in the
    /// sources' order.
    public static func offers(from statuses: [SDKSourceStatus]) -> [SDKOffer] {
        statuses.filter(\.enabled).flatMap { status in
            (status.branches ?? []).compactMap { branch in
                version(ofBranch: branch, prefix: status.branchPrefix).map {
                    SDKOffer(source: status.name, url: status.url, branch: branch, version: $0)
                }
            }
        }
    }
}

/// What the enabled sources offer, and why any of them could not be read.
public struct SDKOffers: Sendable, Equatable {
    public var offers: [SDKOffer]
    /// `<source>: <reason>`, one per enabled source that could not be read.
    public var problems: [String]

    public init(offers: [SDKOffer] = [], problems: [String] = []) {
        self.offers = offers
        self.problems = problems
    }
}

/// Where toolchain setup gets an SDK when no registered one fits: the
/// enabled sources, listed and fetched the way the SDK page does it.
public protocol SDKSupplier: Sendable {
    /// Whether any source is enabled; read from the file, no network.
    var hasEnabledSource: Bool { get }

    /// The branches the enabled sources list (network).
    func offers() -> SDKOffers

    /// Imports `offer` in `staging` (empty, the caller's own) and answers
    /// the registered record.
    func fetch(
        _ offer: SDKOffer,
        staging: URL,
        hasSwiftToolchain: Bool,
        reporter: TaskReporter,
    ) async throws -> SDKRecord
}

/// The sources in `Environment/sdk-sources.json`, imported through the SDK
/// manager by a shallow clone of one branch, as `sdkImport` does it.
public struct SourceSDKSupplier: SDKSupplier {
    let layout: EnvironmentLayout

    public init(layout: EnvironmentLayout) {
        self.layout = layout
    }

    public var hasEnabledSource: Bool {
        SDKSourceList.load(layout).hasEnabledSource
    }

    public func offers() -> SDKOffers {
        let statuses = SDKSourceList.load(layout).statuses(read: true).filter(\.enabled)
        return SDKOffers(
            offers: SDKOffer.offers(from: statuses),
            problems: statuses.compactMap { status in status.problem.map { "\(status.name): \($0)" } },
        )
    }

    public func fetch(
        _ offer: SDKOffer,
        staging: URL,
        hasSwiftToolchain: Bool,
        reporter: TaskReporter,
    ) async throws -> SDKRecord {
        let manager = SDKManager(layout: layout)
        let prepared = try manager.prepare(
            SDKImportRequest(source: .repository(url: offer.url, branch: offer.branch)),
            descriptors: [],
        )
        return try await manager.run(
            prepared,
            staging: staging,
            hasSwiftToolchain: hasSwiftToolchain,
            reporter: reporter,
        )
    }
}
