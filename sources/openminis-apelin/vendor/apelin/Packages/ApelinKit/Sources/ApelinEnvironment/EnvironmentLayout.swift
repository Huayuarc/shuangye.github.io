import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// Where apelin-environment keeps things, all of it in the data folder and
/// all of it mobile's:
///
/// ```
/// ~/Documents/wiki.qaq.apelin/
///   inbox/                      folders and archives pushed for import
///   Exports/<kind>-<id>/<name>  a transfer file (.apetc, .apesdk, .apeproj)
///                               written for the app to share, then deleted
///   SDKs/<CanonicalName>-<sha8>/  a registered SDK's tree
///   SDKs/.registry/<id>.json    its record; written last, so it is the commit
///   Settings/git.json           {"authorName", "authorEmail"}
///   Environment/
///     staging/<task>/           one task's private work, removed after it
///     clones/<task>             the project folder a running clone is making
///     sdk-sources.json          the configured SDK sources
///     Artifacts/<name>.deb      local packages handed to the install bridge
///     Toolchains/registry.json  registered toolchains and the default
///     Toolchains/jobs/<key>/    one setup's staging and stage record, kept
///                               for resume until it reaches ready
/// ```
///
/// The final toolchain goes to `<install root>/usr/lib/apelin/toolchains/<id>/`
/// through the install bridge, never here.
public struct EnvironmentLayout: Sendable {
    public let data: DataFolder
    /// The install root apelind derived from its own path (the worker's
    /// assignment carries it).
    public let installRoot: String
    /// Mobile's home as the host set it; with the install root it says which
    /// bootstrap this is (roothide keeps mobile's home inside the root).
    public let home: String

    public init(data: DataFolder, installRoot: String, home: String) {
        self.data = data
        self.installRoot = installRoot
        self.home = home
    }

    public init(assignment: WorkerAssignment) {
        self.init(data: DataFolder(home: assignment.home), installRoot: assignment.installRoot, home: assignment.home)
    }

    public var inbox: URL {
        data.root.appendingPathComponent("inbox", isDirectory: true)
    }

    public var exports: URL {
        data.exports
    }

    public var sdks: URL {
        data.sdks
    }

    public var sdkRegistry: URL {
        data.sdkRegistry
    }

    public var settings: URL {
        data.root.appendingPathComponent("Settings", isDirectory: true)
    }

    public var gitSettings: URL {
        settings.appendingPathComponent("git.json")
    }

    public var environment: URL {
        data.environment
    }

    public var staging: URL {
        environment.appendingPathComponent("staging", isDirectory: true)
    }

    public var cloneMarkers: URL {
        environment.appendingPathComponent("clones", isDirectory: true)
    }

    public var sdkSources: URL {
        environment.appendingPathComponent("sdk-sources.json")
    }

    public var artifacts: URL {
        environment.appendingPathComponent("Artifacts", isDirectory: true)
    }

    public var toolchains: URL {
        data.toolchains
    }

    public var toolchainRegistry: URL {
        data.toolchainRegistry
    }

    public var toolchainJobs: URL {
        toolchains.appendingPathComponent("jobs", isDirectory: true)
    }

    /// roothide when the host put mobile's home inside the install root;
    /// rootless otherwise. Read off the host's own decision, never guessed
    /// from a path spelling.
    public var isRoothide: Bool {
        installRoot != "/" && CanonicalPath.isCanonical(home, inside: installRoot)
    }

    /// Makes each missing level below the data folder, refusing symlinks.
    public func make(_ url: URL) throws {
        do {
            try data.makeLevels(to: url)
        } catch {
            throw ApelinError(.unavailable, "cannot make \(url.lastPathComponent) in the data folder: \(error)")
        }
    }

    /// A fresh private staging folder for one task.
    public func makeStaging(_ name: String) throws -> URL {
        try make(staging)
        let url = staging.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        guard mkdir(url.path, 0o700) == 0 else {
            throw ApelinError(.unavailable, "cannot make staging for \(name): \(String(cString: strerror(errno)))")
        }
        return url
    }
}

/// Atomic JSON files: written beside, renamed over.
enum JSONFile {
    static func read<T: Decodable>(_: T.Type, at url: URL) throws -> T? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try JSONCoding.decode(T.self, from: data)
    }

    static func write(_ value: some Encodable, to url: URL) throws {
        let data = try JSONCoding.encoder(pretty: true).encode(value)
        try data.write(to: url, options: .atomic)
    }
}
