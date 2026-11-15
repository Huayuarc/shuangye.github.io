import Darwin
import Foundation

/// What a tool says about its own effect. The host classifies each tool from
/// this *and* what the extension can actually do; a tool cannot skip approval
/// by calling itself read-only.
public enum ToolRisk: String, Codable, Hashable, Sendable {
    /// Reads, never writes.
    case readOnly
    /// Writes inside the project.
    case writeProject
    /// Anything else: the system, other apps, the network.
    case system
}

/// One tool, in the shape `AgentTool` takes: a name, a description and a JSON
/// Schema for the arguments, plus the declared risk and an optional timeout.
public struct ToolDescriptor: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public var risk: ToolRisk
    /// Seconds a call may run; capped by the host's `maxCallTimeout`.
    public var timeoutSeconds: Double?

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        risk: ToolRisk,
        timeoutSeconds: Double? = nil,
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.risk = risk
        self.timeoutSeconds = timeoutSeconds
    }
}

/// `<install root>/usr/share/apelin/agent-tools/<id>/manifest.json`.
public struct ToolManifest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    /// Stable, and the name of the directory the manifest is in.
    public var id: String
    public var name: String
    public var version: String
    /// SPDX expression covering what the executable contains.
    public var license: String
    /// Notices shipped beside the manifest, relative to its directory.
    public var licenseFiles: [String]?
    /// Relative to the install root.
    public var executable: String
    public var protocolVersions: [Int]
    public var tools: [ToolDescriptor]

    public init(
        id: String,
        name: String,
        version: String,
        license: String,
        licenseFiles: [String]? = nil,
        executable: String,
        protocolVersions: [Int] = ToolProtocol.supportedVersions,
        tools: [ToolDescriptor],
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.license = license
        self.licenseFiles = licenseFiles
        self.executable = executable
        self.protocolVersions = protocolVersions
        self.tools = tools
    }

    public func tool(named name: String) -> ToolDescriptor? {
        tools.first { $0.name == name }
    }
}

/// A manifest that passed validation, with every path in it canonical.
public struct ValidatedToolManifest: Hashable, Sendable {
    public let manifest: ToolManifest
    public let installRoot: String
    public let executablePath: String
    public let licensePaths: [String]
}

/// What a file must be for the host to trust it: owned by `requiredOwner`
/// (root on a device), not writable by group or others.
public struct ToolManifestPolicy: Hashable, Sendable {
    public var requiredOwner: uid_t
    public var maxManifestBytes: Int
    public var maxTools: Int

    public init(requiredOwner: uid_t = 0, maxManifestBytes: Int = 256 * 1024, maxTools: Int = 64) {
        self.requiredOwner = requiredOwner
        self.maxManifestBytes = maxManifestBytes
        self.maxTools = maxTools
    }
}

public struct ToolManifestError: Error, Hashable, CustomStringConvertible {
    public var id: String
    public var reason: String
    public var description: String {
        "\(id): \(reason)"
    }

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}

public enum ToolManifestValidator {
    /// Where manifests live, relative to the install root.
    public static let relativeDirectory = "usr/share/apelin/agent-tools"

    /// One result per directory under the agent-tools folder. A bad manifest
    /// is isolated to its own entry; it never hides the others.
    public static func discover(
        installRoot: String,
        policy: ToolManifestPolicy = .init(),
    ) -> [Result<ValidatedToolManifest, ToolManifestError>] {
        let folder = join(installRoot, relativeDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted().map { name in
            Result { try validate(installRoot: installRoot, id: name, policy: policy) }
                .mapError { $0 as? ToolManifestError ?? ToolManifestError(id: name, reason: "\($0)") }
        }
    }

    /// Reads and checks `<installRoot>/usr/share/apelin/agent-tools/<id>/manifest.json`.
    public static func validate(
        installRoot: String,
        id: String,
        policy: ToolManifestPolicy = .init(),
    ) throws -> ValidatedToolManifest {
        func fail(_ reason: String) -> ToolManifestError {
            ToolManifestError(id: id, reason: reason)
        }

        guard isValidID(id) else { throw fail("not a valid extension id") }
        let root: String
        do {
            root = try CanonicalPath.resolve(installRoot)
        } catch {
            throw fail("the install root cannot be resolved: \(error)")
        }

        let directory = try canonical(join(root, relativeDirectory, id), inside: root, fail)
        try checkOwnership(directory, policy: policy, directory: true, fail)
        let manifestPath = try canonical(join(directory, "manifest.json"), inside: directory, fail)
        try checkOwnership(manifestPath, policy: policy, directory: false, fail)

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: manifestPath))
            defer { try? handle.close() }
            data = try handle.read(upToCount: policy.maxManifestBytes + 1) ?? Data()
        } catch {
            throw fail("manifest.json: \(error.localizedDescription)")
        }
        guard data.count <= policy.maxManifestBytes else {
            throw fail("manifest.json is larger than \(policy.maxManifestBytes) bytes")
        }
        let manifest: ToolManifest
        do {
            manifest = try JSONDecoder().decode(ToolManifest.self, from: data)
        } catch {
            throw fail("manifest.json does not parse: \(error)")
        }

        try checkFields(manifest, id: id, policy: policy, fail)

        guard CanonicalPath.isPlainRelative(manifest.executable) else {
            throw fail("executable must be a plain path relative to the install root")
        }
        let executable = try canonical(join(root, manifest.executable), inside: root, fail)
        try checkExecutable(executable, policy: policy, fail)

        var licenses: [String] = []
        for file in manifest.licenseFiles ?? [] {
            guard CanonicalPath.isPlainRelative(file) else {
                throw fail("license file \(file) must be relative to the manifest")
            }
            let path = try canonical(join(directory, file), inside: directory, fail)
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw fail("license file \(file) is not a file")
            }
            licenses.append(path)
        }

        return ValidatedToolManifest(
            manifest: manifest,
            installRoot: root,
            executablePath: executable,
            licensePaths: licenses,
        )
    }

    /// Checks the executable again, right before it is spawned: it may have
    /// changed since the manifest was read.
    public static func recheckExecutable(
        _ validated: ValidatedToolManifest,
        policy: ToolManifestPolicy = .init(),
    ) throws {
        func fail(_ reason: String) -> ToolManifestError {
            ToolManifestError(id: validated.manifest.id, reason: reason)
        }
        let current = try canonical(
            join(validated.installRoot, validated.manifest.executable),
            inside: validated.installRoot,
            fail,
        )
        guard current == validated.executablePath else { throw fail("the executable now resolves elsewhere") }
        try checkExecutable(current, policy: policy, fail)
    }

    public static func isValidID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (3 ... 128).contains(bytes.count), let first = bytes.first, isLowerAlnum(first) else { return false }
        return bytes.allSatisfy { isLowerAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
            && !id.contains("..")
    }

    public static func isValidToolName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1 ... 64).contains(bytes.count), let first = bytes.first else { return false }
        let letter: (UInt8) -> Bool = { ($0 | 0x20) >= UInt8(ascii: "a") && ($0 | 0x20) <= UInt8(ascii: "z") }
        return (letter(first) || first == UInt8(ascii: "_"))
            && bytes.allSatisfy {
                letter($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
            }
    }

    private static func checkFields(
        _ manifest: ToolManifest,
        id: String,
        policy: ToolManifestPolicy,
        _ fail: (String) -> ToolManifestError,
    ) throws {
        guard manifest.schemaVersion == ToolManifest.schemaVersion else {
            throw fail("unknown schemaVersion \(manifest.schemaVersion)")
        }
        guard manifest.id == id else { throw fail("manifest id \(manifest.id) does not match its directory") }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw fail("name is empty")
        }
        guard manifest.version.range(of: #"^[0-9A-Za-z.+~:-]{1,64}$"#, options: .regularExpression) != nil else {
            throw fail("version is not a package version")
        }
        guard !manifest.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw fail("license is empty")
        }
        guard manifest.protocolVersions.contains(where: ToolProtocol.supportedVersions.contains) else {
            throw fail("supports protocol versions \(manifest.protocolVersions), but this host supports only \(ToolProtocol.supportedVersions)")
        }
        guard !manifest.tools.isEmpty, manifest.tools.count <= policy.maxTools else {
            throw fail("must declare between 1 and \(policy.maxTools) tools")
        }
        var seen = Set<String>()
        for tool in manifest.tools {
            guard isValidToolName(tool.name) else { throw fail("tool name \(tool.name) is not valid") }
            guard seen.insert(tool.name).inserted else { throw fail("tool \(tool.name) is declared twice") }
            guard !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw fail("tool \(tool.name) has no description")
            }
            guard tool.parameters["type"] == "object" else {
                throw fail("tool \(tool.name): parameters must be an object schema")
            }
            if let timeout = tool.timeoutSeconds, !(timeout > 0) {
                throw fail("tool \(tool.name): timeoutSeconds must be positive")
            }
        }
    }

    private static func canonical(
        _ path: String,
        inside root: String,
        _ fail: (String) -> ToolManifestError,
    ) throws -> String {
        let resolved: String
        do { resolved = try CanonicalPath.resolve(path) } catch { throw fail("\(error)") }
        guard CanonicalPath.isInside(resolved, root: root) else { throw fail("\(path) resolves outside \(root)") }
        return resolved
    }

    @discardableResult
    private static func checkOwnership(
        _ path: String,
        policy: ToolManifestPolicy,
        directory: Bool,
        _ fail: (String) -> ToolManifestError,
    ) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw fail("\(path): \(String(cString: strerror(errno)))") }
        let kind = info.st_mode & S_IFMT
        guard kind == (directory ? S_IFDIR : S_IFREG) else {
            throw fail("\(path) is not a \(directory ? "directory" : "regular file")")
        }
        guard info.st_uid == policy.requiredOwner else {
            throw fail("\(path) is owned by uid \(info.st_uid), not \(policy.requiredOwner)")
        }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw fail("\(path) is writable by group or others") }
        return info
    }

    private static func checkExecutable(
        _ path: String,
        policy: ToolManifestPolicy,
        _ fail: (String) -> ToolManifestError,
    ) throws {
        let info = try checkOwnership(path, policy: policy, directory: false, fail)
        guard info.st_mode & S_IXUSR != 0 else { throw fail("\(path) is not executable by its owner") }
    }

    private static func isLowerAlnum(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= 0x30 && byte <= 0x39)
    }

    private static func join(_ parts: String...) -> String {
        var result = parts[0]
        for part in parts.dropFirst() {
            if !result.hasSuffix("/") {
                result += "/"
            }
            result += part
        }
        return result
    }
}
