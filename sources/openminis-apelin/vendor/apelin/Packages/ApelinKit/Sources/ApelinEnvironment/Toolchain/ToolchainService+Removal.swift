import ApelinProtocol

public extension ToolchainService {
    // MARK: Removal

    /// Checks a removal before the task is accepted.
    func prepareRemoval(_ request: ToolchainRemoveRequest) throws -> ToolchainRecord {
        guard let record = ToolchainRegistry.load(layout).toolchains.first(where: { $0.id == request.id }) else {
            throw ApelinError(.notFound, "no toolchain \(request.id.debugDescription)")
        }
        let users = projects.projects(usingToolchain: record.id)
        guard users.isEmpty else {
            throw ApelinError(
                .conflict,
                "\(record.id) is used by \(users.joined(separator: ", ")). Move these projects to another toolchain first.",
            )
        }
        guard record.installationID != nil else {
            throw ApelinError(
                .conflict,
                "Apelin has no install record for \(record.id). Remove its package with your preferred package manager.",
            )
        }
        return record
    }

    func remove(
        _ record: ToolchainRecord,
        installer: any PackageInstaller,
        reporter: TaskReporter,
    ) async throws {
        reporter.stage("removing")
        if let installationID = record.installationID {
            do {
                try await Self.settled {
                    try await installer.remove(installationID: installationID, reporter: reporter)
                }
            } catch let error as ApelinError
                where [.conflict, .notFound].contains(error.code) && !Self.exists(record.path)
            {
                // The bridge no longer manages it and its tree is gone: the
                // package was removed from outside. Only the record is left.
                reporter.warning("\(record.id) was already removed outside Apelin (\(error.message)); unregistering it")
            }
        }
        var registry = ToolchainRegistry.load(layout)
        registry.toolchains.removeAll { $0.id == record.id }
        if registry.defaultID == record.id {
            registry.defaultID = registry.toolchains.last?.id
        }
        try registry.save(layout)
    }
}
