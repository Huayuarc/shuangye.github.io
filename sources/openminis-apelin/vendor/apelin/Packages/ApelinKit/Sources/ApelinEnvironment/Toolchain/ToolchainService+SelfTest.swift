import ApelinProtocol
import Foundation

public extension ToolchainService {
    // MARK: Self-test again

    func prepareSelfTest(_ request: ToolchainSelfTestRequest) throws -> ToolchainRecord {
        guard backend.isAvailable else {
            throw ApelinError(.unavailable, UnavailableToolchainBackend.selfTestUnavailable)
        }
        guard let record = ToolchainRegistry.load(layout).toolchains.first(where: { $0.id == request.id }) else {
            throw ApelinError(.notFound, "no toolchain \(request.id.debugDescription)")
        }
        guard Self.exists(record.path) else {
            throw ApelinError(
                .conflict,
                "The files for \(record.id) are missing. Remove the toolchain and set it up again.",
            )
        }
        return record
    }

    /// The installed tree tested again, in a scratch folder of this task's
    /// own, against the SDK setup used — or, removed since, the one setup
    /// would pick now. The record keeps the new results whatever they are.
    func selfTest(
        _ record: ToolchainRecord,
        taskID: TaskID,
        reporter: TaskReporter,
    ) async throws -> ToolchainRecord {
        reporter.stage("validating")
        let swift = record.components.contains { $0.kind == .swift }
        let registered = try sdks.list()
        let sdk: SDKRecord
        if let version = record.selfTestSDK, let match = registered.first(where: { $0.version == version }) {
            sdk = match
        } else {
            let productID = record.origin?.split(separator: " ").first.map(String.init)
            guard let product = try await backend.catalog().first(where: { $0.productID == productID }) else {
                throw ApelinError(
                    .notFound,
                    "Apple's catalog no longer lists \(productID ?? record.id) to pick an SDK for",
                )
            }
            sdk = try Self.selfTestSDK(for: product, among: registered, swift: swift)
        }
        let directory = layout.staging.appendingPathComponent("selftest-" + taskID.rawValue, isDirectory: true)
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        try layout.make(scratch)
        defer { try? FileManager.default.removeItem(at: directory) }

        let throttle = ProgressThrottle()
        let results = try await backend.selfTest(
            installed: URL(fileURLWithPath: record.path ?? "", isDirectory: true),
            sdk: URL(fileURLWithPath: sdk.path, isDirectory: true),
            scratch: scratch,
            progress: { update in
                if throttle.shouldEmit() {
                    reporter.progress(
                        "validating",
                        completed: update.completed,
                        total: update.total,
                        detail: update.detail.isEmpty ? nil : update.detail,
                    )
                }
            },
        )
        try reporter.checkCancelled()

        var registry = ToolchainRegistry.load(layout)
        guard let index = registry.toolchains.firstIndex(where: { $0.id == record.id }) else {
            throw ApelinError(.notFound, "\(record.id) was removed while it was being tested")
        }
        registry.toolchains[index].selfTests = results
        registry.toolchains[index].selfTestSDK = sdk.version
        try registry.save(layout)
        let failed = results.filter { !$0.passed }
        for test in failed {
            reporter.warning("The \(test.language) self-test failed on \(test.architecture).")
        }
        return registry.toolchains[index]
    }
}
