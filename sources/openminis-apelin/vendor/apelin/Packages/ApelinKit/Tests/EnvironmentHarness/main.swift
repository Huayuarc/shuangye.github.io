import ApelinCore
import ApelinDebArchive
import ApelinEnvironment
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation

// apelin-environment-harness: the real EnvironmentWorker with a fake
// toolchain backend, for the session host's end-to-end toolchain test
// (Tests/SessionHost/main.swift ▸ Toolchain setup end to end, run by
// `make harness`). Never shipped.
//
//   apelin-environment-harness worker
//       Serves the environment role over descriptor 3, the way
//       Workers/Environment does through WorkerMain — assignment, ready,
//       requests, cancels — minus the drop to mobile, which a Mac user
//       cannot make. Toolchain setup installs through the host's bridge
//       (HostPackageInstaller over ChannelTransport), like the device.
//   apelin-environment-harness unpack <deb> <root> [<prefix>]
//       What the fake irisind does with a package: every data member
//       written under <root>, <prefix> (rootless's /var/jb) taken off;
//       prints the paths it wrote, one per line.

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "worker":
    serveWorker()
case "unpack" where arguments.count >= 4:
    do {
        try unpack(arguments[2], into: arguments[3], stripping: arguments.count > 4 ? arguments[4] : "")
        exit(0)
    } catch {
        fputs("unpack: \(error)\n", stderr)
        exit(1)
    }
default:
    fputs("usage: apelin-environment-harness worker | unpack <deb> <root> [<prefix>]\n", stderr)
    exit(EX_USAGE)
}

// MARK: - The worker

func serveWorker() -> Never {
    signal(SIGPIPE, SIG_IGN)
    let channel = WorkerChannel(adopting: 3)
    let box = Box()
    channel.onClose { exit(0) }
    channel.onControl { frame in
        switch frame.header.name {
        case WorkerControl.assign?:
            guard let assignment = try? JSONCoding.decode(WorkerAssignment.self, from: frame.body), assignment.role == .environment else { exit(EX_PROTOCOL) }
            setenv("HOME", assignment.home, 1)
            box.worker = EnvironmentWorker(
                layout: EnvironmentLayout(assignment: assignment),
                backend: HarnessBackend(),
                installer: HostPackageInstaller(host: ApelinService(transport: ChannelTransport(channel: channel))),
                emit: { taskID, kind, payload in try? channel.sendEvent(taskID: taskID, kind: kind, payload: payload) },
            )
            try? channel.sendControl(WorkerControl.ready)
        case WorkerControl.cancel?:
            if let taskID = frame.header.taskID {
                box.worker?.cancel(taskID)
            }
        default:
            break
        }
    }
    channel.onRequest { request in
        guard let worker = box.worker else { return (.failure(request.request.requestID, ApelinError(.unavailable, "no assignment yet")), []) }
        return await worker.handle(request)
    }
    channel.start()
    dispatchMain()
}

final class Box: @unchecked Sendable {
    private let lock = PthreadLock()
    private var stored: EnvironmentWorker?
    var worker: EnvironmentWorker? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Holds to Packages/ApelinToolchain's contract on a tree small enough for
/// a test: a "retargeted" tree with a manifest of per-file SHA-256s; install
/// only when the installed bytes do not match, verify them after, then
/// self-test the installed copy — its `clang` run from the install root,
/// the SDK required canonical and registered. `Environment/harness-fail-
/// self-test` in the data folder makes the C case fail.
struct HarnessBackend: ToolchainBackend {
    static let id = "a1b2c3d4e5f60718293a4b5c"

    var isAvailable: Bool {
        true
    }

    func catalog() async throws -> [ToolchainProduct] {
        [ToolchainProduct(productID: "099-00027", version: "27.0", url: "https://example.invalid/CLTools_Executables.pkg", size: 4, upstreamDigest: "0", upstreamDigestAlgorithm: "xar-toc-sha1")]
    }

    func prepare(product: ToolchainProduct, components: [ToolchainComponentKind], staging _: URL, output: URL, progress: @escaping @Sendable (ToolchainBackendProgress) -> Void) async throws -> PreparedToolchain {
        for stage in ["downloading", "extracting", "adapting"] {
            progress(ToolchainBackendProgress(stage: stage))
        }
        let manager = FileManager.default
        if !manager.fileExists(atPath: output.appendingPathComponent("manifest.json").path) {
            try? manager.removeItem(at: output)
            for folder in ["usr/bin", "usr/lib/clang/27/include"] {
                try manager.createDirectory(at: output.appendingPathComponent(folder), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let clang = output.appendingPathComponent("usr/bin/clang")
            try Data("#!/bin/sh\necho apelin-ok\n".utf8).write(to: clang)
            chmod(clang.path, 0o700)
            let header = output.appendingPathComponent("usr/lib/clang/27/include/stddef.h")
            try Data("typedef unsigned long size_t;\n".utf8).write(to: header)
            chmod(header.path, 0o600)
            try manager.createSymbolicLink(atPath: output.appendingPathComponent("usr/bin/cc").path, withDestinationPath: "clang")
            let files = try Dictionary(uniqueKeysWithValues: ["usr/bin/clang", "usr/lib/clang/27/include/stddef.h"].map { try ($0, sha256(output.appendingPathComponent($0))) })
            let manifest = try JSONSerialization.data(withJSONObject: ["id": Self.id, "files": files], options: [.sortedKeys])
            try manifest.write(to: output.appendingPathComponent("manifest.json"))
        }
        progress(ToolchainBackendProgress(stage: "packaging"))
        let manifest = try Data(contentsOf: output.appendingPathComponent("manifest.json"))
        let files = try (JSONSerialization.jsonObject(with: manifest) as? [String: Any])?["files"] as? [String: String] ?? [:]
        return PreparedToolchain(id: Self.id, product: product, components: components, tree: output, files: files, installRelativePath: "usr/lib/apelin/toolchains/" + Self.id, manifest: manifest)
    }

    func installAndValidate(_ prepared: PreparedToolchain, installRoot: URL, sdk: URL, journal _: URL, scratch _: URL, install: @escaping ToolchainInstallStep, progress: @escaping @Sendable (ToolchainBackendProgress) -> Void) async throws -> [ToolchainSelfTestResult] {
        guard CanonicalPath.resolve(installRoot.path) == installRoot.path, CanonicalPath.resolve(sdk.path) == sdk.path else {
            throw ApelinError(.internal, "the install root and the SDK must come canonical")
        }
        guard FileManager.default.fileExists(atPath: sdk.appendingPathComponent("SDKSettings.json").path) else {
            throw ApelinError(.internal, "the SDK is not a registered SDK")
        }
        let destination = installRoot.appendingPathComponent(prepared.installRelativePath)
        progress(ToolchainBackendProgress(stage: "installing"))
        if (try? verify(prepared, at: destination)) == nil {
            try await install(prepared)
        }
        try Task.checkCancellation()
        try verify(prepared, at: destination)

        progress(ToolchainBackendProgress(stage: "validating"))
        let failing = FileManager.default.fileExists(atPath: (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/Documents/wiki.qaq.apelin/Environment/harness-fail-self-test")
        let output = try run(destination.appendingPathComponent("usr/bin/clang"))
        let passed = output.contains("apelin-ok")
        return ["C", "C++", "ObjC"].map { language in
            ToolchainSelfTestResult(language: language, architecture: "arm64", passed: passed && !(failing && language == "C"), detail: "ran \(destination.path)/usr/bin/clang against \(sdk.path)")
        }
    }

    /// Every manifest file under `root`, with its digest, and nothing in the
    /// tree writable by anyone but its owner.
    func verify(_ prepared: PreparedToolchain, at root: URL) throws {
        for (relative, digest) in prepared.files {
            let file = root.appendingPathComponent(relative)
            guard let resolved = CanonicalPath.resolve(file.path), CanonicalPath.isCanonical(resolved, inside: CanonicalPath.resolve(root.path) ?? root.path),
                  try sha256(file) == digest
            else {
                throw ApelinError(.internal, "toolchain content digest mismatch: \(relative)")
            }
            var metadata = stat()
            guard stat(file.path, &metadata) == 0, metadata.st_mode & 0o022 == 0, metadata.st_mode & 0o044 == 0o044 else {
                throw ApelinError(.internal, "\(relative) is not installed readable by all and writable by its owner alone")
            }
        }
    }

    func run(_ executable: URL) throws -> String {
        let process = Process()
        process.executableURL = executable
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

func sha256(_ url: URL) throws -> String {
    try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Unpacking, as irisind would

func unpack(_ deb: String, into root: String, stripping prefix: String) throws {
    let contents = try DebArchiveReader.contents(of: .path(deb), contentsLimit: 64 << 20)
    let manager = FileManager.default
    var written: [String] = []
    for entry in contents.entries {
        var path = entry.path
        if !prefix.isEmpty {
            guard path == prefix || path.hasPrefix(prefix + "/") else { throw ApelinError(.badRequest, "\(path) is outside \(prefix)") }
            path = String(path.dropFirst(prefix.count))
        }
        guard CanonicalPath.isPlainRelative(String(path.drop { $0 == "/" })) || path.isEmpty || path == "/" else { continue }
        let target = root + path
        switch entry.kind {
        case .directory:
            if !manager.fileExists(atPath: target) {
                try manager.createDirectory(atPath: target, withIntermediateDirectories: true)
            }
            chmod(target, mode_t(entry.mode))
        case .file:
            try (entry.contents ?? Data()).write(to: URL(fileURLWithPath: target))
            chmod(target, mode_t(entry.mode))
            written.append(target)
        case let .symbolicLink(destination):
            try? manager.removeItem(atPath: target)
            try manager.createSymbolicLink(atPath: target, withDestinationPath: destination)
            written.append(target)
        default:
            throw ApelinError(.badRequest, "\(entry.path): not a file, folder or link")
        }
    }
    print(written.joined(separator: "\n"))
}
