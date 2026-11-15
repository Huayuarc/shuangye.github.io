import ApelinCore
import ApelinDebArchive
import ApelinDebian
import ApelinProtocol
import CryptoKit
import Foundation

/// A local package the install bridge is handed.
public struct LocalArtifact: Codable, Sendable, Equatable {
    /// `toolchain-<id>`. The file is `Environment/Artifacts/<artifactID>.deb`
    /// in the data folder; the session host reads it from there, copies it
    /// to its private staging and checks `digest` before handing it to irisind.
    public var artifactID: String
    public var path: String
    /// SHA-256 of the file.
    public var digest: String
    public var packageID: String
    public var version: String
}

/// How the environment worker gets a package installed and removed: through
/// the session host's install bridge (installPackage / removePackage), never
/// apt or dpkg.
///
/// An install is two steps so the caller can record the host's install task
/// between them: a setup resumed after `startInstall` answered — re-run by
/// the user or re-sent by the host after a restart — follows that task with
/// `finishInstall` instead of submitting the package again (the host keeps
/// and resumes its install tasks under their own IDs).
public protocol PackageInstaller: Sendable {
    /// Hands the package to the bridge; answers its install task.
    func startInstall(_ artifact: LocalArtifact) async throws -> TaskHandle
    /// Follows an install task to its end. Throws `unavailable` when the
    /// task could not be read to its end (it may still be running), any
    /// other error when it ended without installing or is gone.
    func finishInstall(_ handle: TaskHandle, reporter: TaskReporter) async throws -> InstallResult
    func remove(installationID: String, reporter: TaskReporter) async throws
}

public extension PackageInstaller {
    func install(_ artifact: LocalArtifact, reporter: TaskReporter) async throws -> InstallResult {
        try await finishInstall(startInstall(artifact), reporter: reporter)
    }
}

/// The bridge, through the worker's channel to the host.
public struct HostPackageInstaller: PackageInstaller {
    public let host: ApelinService

    public init(host: ApelinService) {
        self.host = host
    }

    public func startInstall(_ artifact: LocalArtifact) async throws -> TaskHandle {
        try await host.installPackage(artifactID: artifact.artifactID, digest: artifact.digest)
    }

    public func finishInstall(_ handle: TaskHandle, reporter: TaskReporter) async throws -> InstallResult {
        let last = try await follow(handle, reporter: reporter)
        guard let payload = last, let result = try? payload.decode(InstallResult.self) else {
            throw ApelinError(.internal, "the install finished without a result")
        }
        return result
    }

    public func remove(installationID: String, reporter: TaskReporter) async throws {
        let handle = try await host.removePackage(installationID: installationID)
        _ = try await follow(handle, reporter: reporter)
    }

    /// Reads the task to its end; answers the payload of its last `result`.
    /// A stream that stops before the task's final `state` is not an answer.
    private func follow(_ handle: TaskHandle, reporter: TaskReporter) async throws -> JSONValue? {
        var result: JSONValue?
        var finished = false
        for try await event in host.events(of: handle) {
            switch event.kind {
            case "result":
                result = event.payload
            case TaskEvent.stateKind:
                let state = event.payload?["state"]?.stringValue
                guard let state, TaskState(rawValue: state)?.isTerminal == true else { continue }
                guard state == TaskState.succeeded.rawValue else {
                    let message = event.payload?["message"]?.stringValue ?? state
                    throw ApelinError(
                        state == TaskState.cancelled.rawValue ? .cancelled : .internal,
                        "install bridge: \(message)",
                    )
                }
                finished = true
            default:
                reporter.emit("install." + event.kind, event.payload)
            }
        }
        guard finished else {
            throw ApelinError(
                .unavailable,
                "install bridge: task \(handle.taskID.rawValue) stopped answering before it ended",
            )
        }
        return result
    }
}

/// Writes a prepared toolchain tree as a local deb for this bootstrap.
public struct ToolchainPackager: Sendable {
    public let layout: EnvironmentLayout

    public init(layout: EnvironmentLayout) {
        self.layout = layout
    }

    public static func packageID(for id: String) -> String {
        "wiki.qaq.apelin.toolchain." + id.lowercased()
    }

    /// What a package manager lists it as, beside the ID that keeps side-by-side
    /// toolchains apart: "Command Line Tools 15.0 with Swift (Apelin)".
    static func name(of prepared: PreparedToolchain) -> String {
        let swift = prepared.components.contains(.swift) ? " with Swift" : ""
        return "Command Line Tools \(prepared.product.version)\(swift) (Apelin)"
    }

    /// Every toolchain's package manager icon: one for all of them, drawn
    /// by Scripts/render-package-icons.py and served by the project's Pages.
    static let icon = "https://owngoal-dev.github.io/Apelin/icons/wiki.qaq.apelin.toolchain.png"

    public func package(_ prepared: PreparedToolchain) throws -> LocalArtifact {
        let packageLayout: PackageLayout = layout.isRoothide ? .roothide : .rootless
        let packageID = Self.packageID(for: prepared.id)
        let version = prepared.product.version.filter { $0.isNumber || $0 == "." } + "+" + prepared.id.prefix(8)
        var control = DebianControlFile(
            package: packageID,
            version: version.first?.isNumber == true ? version : "0" + version,
            architecture: packageLayout.architecture,
            description: "Apelin toolchain \(prepared.id)\nApple Command Line Tools \(prepared.product.version) retargeted on this device. Built locally; never redistributed.",
        )
        control["Name"] = Self.name(of: prepared)
        control["Icon"] = Self.icon
        control["Maintainer"] = "Apelin (built on this device)"
        control["Section"] = "Development"
        control["Priority"] = "optional"

        var writer = DebPackageWriter(control: control)
        // the session host reads control.tar before it installs; gzip it can open
        writer.controlCompression = .gzip
        let destination = try packageLayout.packagePath(for: "/" + prepared.installRelativePath)
        writer.entries = try Self.installable(
            DebEntry.tree(fromDirectory: prepared.tree.path, at: destination),
            under: destination,
        )

        try layout.make(layout.artifacts)
        let artifactID = "toolchain-" + prepared.id
        let path = layout.artifacts.appendingPathComponent(artifactID + ".deb")
        try? FileManager.default.removeItem(at: path)
        try writer.write(toPath: path.path)
        return try LocalArtifact(
            artifactID: artifactID,
            path: path.path,
            digest: Self.sha256(path),
            packageID: packageID,
            version: control.version ?? version,
        )
    }

    /// The tree as root installs it and mobile runs it: every entry root's
    /// (the writer's rule), folders 0755, files 0755 when any execute bit
    /// was set and 0644 otherwise — readable by mobile, writable by root
    /// alone, no setuid, setgid or sticky bit. A link must stay inside the
    /// toolchain: relative, and never climbing out of it when followed as
    /// the kernel follows it, through the tree's own links.
    static func installable(_ entries: [DebEntry], under root: String) throws -> [DebEntry] {
        let rootDepth = CanonicalPath.components(root).count
        let relative = { (path: String) in CanonicalPath.components(path).dropFirst(rootDepth).map(String.init) }
        var links: [[String]: String] = [:]
        for entry in entries {
            if case let .symbolicLink(target) = entry.kind {
                links[relative(entry.path)] = target
            }
        }
        return try entries.map { entry in
            var entry = entry
            switch entry.kind {
            case .directory:
                entry.mode = 0o755
            case .file:
                entry.mode = entry.mode & 0o111 != 0 ? 0o755 : 0o644
            case let .symbolicLink(target):
                guard !target.hasPrefix("/"),
                      !CanonicalPath.containsNUL(target),
                      staysInside(relative(entry.path), links: links)
                else {
                    throw ApelinError(.internal, "the toolchain tree links \(entry.path) to \(target), outside itself")
                }
            }
            return entry
        }
    }

    /// Follows the link at `link` (components below the root) component by
    /// component, expanding every link of the tree it passes through. False
    /// when a step climbs above the root, a link on the way is absolute, or
    /// the links are followed more than the kernel would (`MAXSYMLINKS`),
    /// which a loop always is. A component the tree does not have is taken
    /// as a plain folder: nothing below it resolves on the device anyway.
    static func staysInside(_ link: [String], links: [[String]: String]) -> Bool {
        guard let target = links[link] else { return false }
        var directory = Array(link.dropLast())
        // Reversed, so the next component is the last.
        var remaining = CanonicalPath.components(target).reversed().map(String.init)
        var hops = 1
        while let component = remaining.popLast() {
            if component == ".." {
                guard !directory.isEmpty else { return false }
                directory.removeLast()
                continue
            }
            let candidate = directory + [component]
            guard let next = links[candidate] else {
                directory = candidate
                continue
            }
            hops += 1
            guard hops <= maximumLinkHops, !next.hasPrefix("/") else { return false }
            remaining += CanonicalPath.components(next).reversed().map(String.init)
        }
        return true
    }

    /// The kernel's own bound on links followed in one lookup.
    static let maximumLinkHops = 32

    static func sha256(_ url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw ArchiveExtractor.posix("open \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return TransferDigest.hex(hash.finalize())
    }
}
