import ApelinCore
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation

// Toolchain setup end to end: the real EnvironmentWorker in its own process
// (apelin-environment-harness, a fake toolchain backend and nothing else
// fake), wired to this host's install bridge the way SessionHost wires a
// worker — CallerPolicy, the worker's own role, events only into tasks it
// owns — with the fake irisind laying the package's files down under a
// temporary roothide install root. Setup → the bridge → irisind → the
// self-test on the installed bytes → the registry, then toolchainRemove
// through removePackage; and a failed self-test rolled back on the way.

/// The worker, spawned with its end of a socketpair as descriptor 3 and
/// served like SessionHost serves one (Dispatcher, the install handler, the
/// registry's attach) — the parts this half can compile.
final class EnvironmentHarness: @unchecked Sendable {
    let channel: WorkerChannel
    let pid: pid_t
    let registry: TaskRegistry
    let bridge: InstallBridge
    let caller = Caller.worker(.environment, instance: nil)

    init(executable: String, assignment: WorkerAssignment, registry: TaskRegistry, bridge: InstallBridge) throws {
        self.registry = registry
        self.bridge = bridge
        let (local, remote) = try WorkerChannel.makePair()
        defer { close(remote) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, remote, 3)
        var spawned: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("worker"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { (argv + envp).forEach { free($0) } }
        let status = posix_spawn(&spawned, executable, &actions, nil, argv, envp)
        guard status == 0 else {
            throw ApelinError(.unavailable, "spawning the harness: \(String(cString: strerror(status)))")
        }
        pid = spawned
        channel = WorkerChannel(adopting: local)

        let ready = DispatchSemaphore(value: 0)
        channel.onControl { frame in
            if frame.header.name == WorkerControl.ready {
                ready.signal()
            }
        }
        channel.onRequest { [self] request in await serve(request) }
        channel.onEvent { [registry, caller] frame in
            guard let taskID = frame.header.taskID, let kind = frame.header.name else { return }
            let payload = frame.body.isEmpty ? nil : try? JSONCoding.decode(JSONValue.self, from: frame.body)
            Task {
                // A worker writes only to tasks it was given.
                guard let record = await registry.record(taskID), case let .worker(role, key) = caller, record.owner == role, record.ownerKey == key else { return }
                await registry.append(taskID, kind: kind, payload: payload)
            }
        }
        channel.start()
        try channel.sendControl(WorkerControl.assign, body: assignment)
        guard ready.wait(timeout: .now() + 10) == .success else {
            throw ApelinError(.unavailable, "the harness did not answer its assignment")
        }
    }

    /// What the worker asks the host for, decided as Dispatcher decides it.
    private func serve(_ request: ChannelRequest) async -> (WireReply, [OwnedDescriptor]) {
        let id = request.request.requestID
        guard CallerPolicy.allows(caller, request.request.operation) else {
            return (
                .failure(
                    id,
                    ApelinError(.denied, "\(request.request.operation.rawValue) is not available to this caller"),
                ),
                [],
            )
        }
        do {
            switch request.request.operation {
            case .installPackage:
                return try await (
                    .success(
                        id,
                        bridge.install(request.request.decode(InstallPackageRequest.self), caller: caller),
                    ),
                    [],
                )
            case .removePackage:
                return try await (
                    .success(
                        id,
                        bridge.remove(request.request.decode(RemovePackageRequest.self), caller: caller),
                    ),
                    [],
                )
            case .buildAttach:
                let attach = try request.request.decode(BuildAttachRequest.self)
                return try await (
                    .success(
                        id,
                        registry.attach(
                            attach.taskID,
                            as: .buildAttach,
                            afterSeq: attach.afterSeq,
                            waitMilliseconds: attach.waitMilliseconds,
                        ),
                    ),
                    [],
                )
            default:
                return (.failure(id, .unimplemented(request.request.operation)), [])
            }
        } catch let error as ApelinError {
            return (.failure(id, error), [])
        } catch {
            return (.failure(id, ApelinError(.internal, String(describing: error))), [])
        }
    }

    /// The app's side, as SessionHost.startTask does it.
    func start(_ request: some OperationRequest) async throws -> TaskHandle {
        let handle = await registry.create(kind: .environment, owner: .environment)
        let (reply, _) = try await channel.call(WireRequest(request), taskID: handle.taskID)
        if case let .failure(error) = reply.result {
            await registry.finish(handle.taskID, .failed, message: error.description)
            throw error
        }
        return handle
    }

    func ask<R: OperationRequest>(_ request: R) async throws -> R.Response {
        let (reply, _) = try await channel.call(WireRequest(request))
        return try JSONCoding.decode(R.Response.self, from: reply.result.get())
    }

    /// Reads an environment task to its end.
    func end(_ handle: TaskHandle, seconds: Double = 60) async throws -> TaskEventBatch {
        let deadline = Date().addingTimeInterval(seconds)
        var batch = try await registry.attach(
            handle.taskID,
            as: .environmentAttach,
            afterSeq: .start,
            waitMilliseconds: 0,
        )
        while !batch.finished, Date() < deadline {
            batch = try await registry.attach(
                handle.taskID,
                as: .environmentAttach,
                afterSeq: .start,
                waitMilliseconds: 500,
            )
        }
        return batch
    }

    func stop() {
        channel.close()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

func toolchainEndToEnd(harness: String) async throws {
    let manager = FileManager.default
    let base = scratchPath + "/toolchain-e2e"
    // roothide: mobile's home inside the install root, packages spelled from /.
    let installRoot = base + "/jbroot"
    let home = installRoot + "/var/mobile"
    let data = DataFolder(home: home)
    let state = URL(fileURLWithPath: base + "/state")
    try manager.createDirectory(at: data.root, withIntermediateDirectories: true)
    try manager.createDirectory(at: state, withIntermediateDirectories: true)

    // The fake irisind installs by unpacking the submitted package with the
    // harness's reader, and removes as roothide's dpkg does: every file and
    // link the package lists goes, and each of its folders stays behind with
    // the `.jbroot` link roothide adds to it, which no package lists.
    let irisin = FakeIrisin(root: installRoot)
    irisin.onInstall = { descriptor in
        let copy = base + "/submitted-\(UUID().uuidString).deb"
        defer { unlink(copy) }
        let output = open(copy, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var offset: off_t = 0
        while true {
            let count = pread(descriptor, &buffer, buffer.count, offset)
            guard count > 0 else { break }
            _ = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress, count) }
            offset += off_t(count)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: harness)
        process.arguments = ["unpack", copy, installRoot]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ApelinError(.internal, "unpacking failed") }
    }
    irisin.onRemove = { packageID in
        let id = String(packageID.dropFirst(ManagedPackagePolicy.toolchainPrefix.count))
        let tree = installRoot + "/usr/lib/apelin/toolchains/" + id
        var folders = [tree]
        for case let entry as String in FileManager.default.enumerator(atPath: tree)?.allObjects ?? [] {
            var metadata = stat()
            guard lstat(tree + "/" + entry, &metadata) == 0 else { continue }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                folders.append(tree + "/" + entry)
            } else {
                unlink(tree + "/" + entry)
            }
        }
        for folder in folders {
            symlink(installRoot, folder + "/.jbroot")
        }
    }

    let registry = TaskRegistry(directory: state.appendingPathComponent("tasks"))
    await registry.load()
    let installations = InstallationStore(directory: state.appendingPathComponent("installations"))
    let bridge = InstallBridge(
        paths: .init(
            installRoot: installRoot,
            dataFolder: data.root.path,
            staging: state.appendingPathComponent("staging"),
        ),
        service: irisin,
        registry: registry,
        artifacts: ArtifactRegistry(file: state.appendingPathComponent("artifacts.json")),
        installations: installations,
        packages: FakeDatabase(irisin: irisin),
        fileLists: DpkgFileLists(installRoot: installRoot),
        approvals: ApprovalLedger(directory: state.appendingPathComponent("approvals")),
        pollInterval: 0.01,
    )
    let worker = try EnvironmentHarness(
        executable: harness,
        assignment: WorkerAssignment(role: .environment, installRoot: installRoot, home: home),
        registry: registry,
        bridge: bridge,
    )
    defer { worker.stop() }

    // An SDK first, through the worker as i2-sdk-import does it: the
    // self-test compiles against a registered one.
    let sdk = data.root.appendingPathComponent("inbox/iPhoneOS.sdk")
    let foundation = sdk.appendingPathComponent("System/Library/Frameworks/Foundation.framework")
    try manager.createDirectory(at: foundation.appendingPathComponent("Headers"), withIntermediateDirectories: true)
    write(
        sdk.appendingPathComponent("SDKSettings.json").path,
        #"{"CanonicalName": "iphoneos99.0", "Version": "99.0", "DisplayName": "iOS 99.0"}"#,
    )
    write(
        foundation.appendingPathComponent("Foundation.tbd").path,
        "--- !tapi-tbd\ntbd-version: 4\ntargets: [ arm64e-ios ]\ninstall-name: '/System/Library/Frameworks/Foundation.framework/Foundation'\n...\n",
    )
    write(foundation.appendingPathComponent("Headers/Foundation.h").path, "// Foundation\n")
    let imported = try await worker.end(worker.start(SDKImportRequest(source: .inbox(path: "iPhoneOS.sdk"))))
    check(imported.state == .succeeded, "e2e: the SDK imports (\(imported.events.last?.payload?["message"]?.stringValue ?? ""))")

    let toolchainID = "a1b2c3d4e5f60718293a4b5c"
    let packageID = ManagedPackagePolicy.toolchainPrefix + toolchainID
    let installed = installRoot + "/usr/lib/apelin/toolchains/" + toolchainID
    let environment = data.environment
    let request = ToolchainSetupRequest(source: .appleCatalog(productID: nil), components: [.c])

    // A C self-test that fails: nothing registered, and what was installed
    // removed again through the bridge, by the worker, as its own record.
    write(environment.appendingPathComponent("harness-fail-self-test").path, "")
    let failed = try await worker.end(worker.start(request))
    let failure = failed.events.last?.payload?["message"]?.stringValue ?? ""
    check(failed.state == .failed && failure.contains("C self-test"), "e2e: a failed C self-test fails the setup (\(failure))")
    let rolledBack = await installations.all()
    check(rolledBack.count == 1 && rolledBack.first?.origin == .environment && rolledBack.first?.status == .removed, "e2e: its install is rolled back through removePackage (\(rolledBack.map(\.status)))")
    check(!manager.fileExists(atPath: installed), "e2e: and its files are gone, the folders roothide leaves with them")
    let afterFailure = try await worker.ask(ToolchainStatusRequest())
    check(afterFailure.toolchains.isEmpty, "e2e: nothing is registered")
    let jobs = (try? manager.contentsOfDirectory(atPath: environment.path + "/Toolchains/jobs")) ?? []
    let job = jobs.first.flatMap {
        try? JSONCoding.decode(
            JSONValue.self,
            from: Data(contentsOf: environment.appendingPathComponent("Toolchains/jobs/\($0)/job.json")),
        )
    }
    check(job?["failure"]?.stringValue != nil && job?["installationID"] == nil, "e2e: job.json keeps the failure for a retry, and no installation")

    // Again, passing: resumed from the job, installed, self-tested on the
    // installed bytes, registered with the bridge's installation ID.
    unlink(environment.appendingPathComponent("harness-fail-self-test").path)
    let succeeded = try await worker.end(worker.start(request))
    check(succeeded.state == .succeeded, "e2e: setup succeeds (\(succeeded.events.last?.payload?["message"]?.stringValue ?? ""))")
    let stages = succeeded.events.filter { $0.kind == "stage" }.compactMap { $0.payload?["stage"]?.stringValue }
    check(stages.suffix(4) == ["packaging", "installing", "validating", "ready"], "e2e: the stages end packaging, installing, validating, ready (\(stages))")
    check(succeeded.events.contains { $0.kind == "resumed" }, "e2e: the second setup resumes the first one's job")
    check(succeeded.events.contains { $0.kind == "install.irisin" }, "e2e: irisind's events are relayed into the setup task")
    let record = try succeeded.events.last { $0.kind == "result" }?.payload?["toolchain"]?.decode(ToolchainRecord.self)
    let ours = await installations.all().filter { $0.status == .installed }
    check(ours.count == 1 && ours.first?.packageID == packageID && ours.first?.artifactID == "toolchain-" + toolchainID && ours.first?.origin == .environment,
          "e2e: the bridge recorded the toolchain package as the environment's (\(ours.map(\.packageID)))")
    check(record?.installationID != nil && record?.installationID == ours.first?.installationID, "e2e: the registry carries the bridge's installation ID")
    check(record?.path == CanonicalPath.resolve(installed), "e2e: the record's path is the physical installed tree")
    check(record?.packageID == packageID && record?.components == [ToolchainComponent(kind: .c, selfCheckPassed: true)], "e2e: C passed its self-check")
    check(record?.selfTests?.count == 3 && record?.selfTests?.allSatisfy(\.passed) == true, "e2e: every self-test case passed")

    // What apelin-build binds: the digest over the installed manifest's files.
    let manifest = (try? Data(contentsOf: URL(fileURLWithPath: installed + "/manifest.json")))
        .flatMap { try? JSONCoding.decode(JSONValue.self, from: $0) }
    var digest = SHA256()
    if case let .object(files)? = manifest?["files"] {
        for (path, value) in files.sorted(by: { $0.key < $1.key }) {
            digest.update(data: Data("\(path) \(value.stringValue ?? "")\n".utf8))
        }
    }
    check(record?.contentDigest == digest.finalize().map { String(format: "%02x", $0) }.joined(), "e2e: contentDigest is the installed tree's, as a project binds it")

    var metadata = stat()
    let clangMode = stat(installed + "/usr/bin/clang", &metadata) == 0 ? metadata.st_mode & 0o7777 : 0
    let headerMode = stat(installed + "/usr/lib/clang/27/include/stddef.h", &metadata) == 0
        ? metadata.st_mode & 0o7777
        : 0
    let folderMode = stat(installed + "/usr/bin", &metadata) == 0 ? metadata.st_mode & 0o7777 : 0
    check(clangMode == 0o755 && headerMode == 0o644 && folderMode == 0o755, "e2e: installed modes are 0755, 0644 and 0755 (\(String(clangMode, radix: 8)), \(String(headerMode, radix: 8)), \(String(folderMode, radix: 8)))")
    check((try? manager.destinationOfSymbolicLink(atPath: installed + "/usr/bin/cc")) == "clang", "e2e: links install as links")
    let leftovers = (try? manager.contentsOfDirectory(atPath: environment.path + "/Artifacts")) ?? []
    check(leftovers.isEmpty, "e2e: the local deb is gone once the bridge has its copy (\(leftovers))")
    check(((try? manager.contentsOfDirectory(atPath: environment.path + "/Toolchains/jobs")) ?? []).isEmpty, "e2e: the job folder goes once ready")

    // Set up again: the registered install is reused, nothing installed twice.
    let again = try await worker.end(worker.start(request))
    let installsAfter = await installations.all().count
    check(again.state == .succeeded && installsAfter == rolledBack.count + 1, "e2e: setting up a registered toolchain again installs nothing")

    // toolchainRemove: through removePackage, the worker's own record.
    let removal = try await worker.end(worker.start(ToolchainRemoveRequest(id: toolchainID)))
    check(removal.state == .succeeded, "e2e: toolchainRemove succeeds (\(removal.events.last?.payload?["message"]?.stringValue ?? ""))")
    let removedRecord = await installations.record(record?.installationID ?? "")
    check(removedRecord?.status == .removed, "e2e: the bridge's record says removed")
    check(!manager.fileExists(atPath: installed), "e2e: the installed tree is gone, the folders roothide leaves with it")
    check(manager.fileExists(atPath: installRoot + "/usr/lib/apelin/toolchains"), "e2e: the toolchains folder stays")
    let pruned = removal.events.contains {
        $0.kind == "install.log" && $0.payload?["line"]?.stringValue?.hasPrefix("Removed the empty folders") == true
    }
    check(pruned, "e2e: the removal's log says the folders went")
    let afterRemoval = try await worker.ask(ToolchainStatusRequest())
    check(afterRemoval.toolchains.isEmpty && afterRemoval.defaultID == nil, "e2e: and the registry is empty")
}
