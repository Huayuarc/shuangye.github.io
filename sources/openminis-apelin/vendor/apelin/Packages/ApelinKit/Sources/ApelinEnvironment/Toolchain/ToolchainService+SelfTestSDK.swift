import ApelinCore
import ApelinProtocol
import Foundation

extension ToolchainService {
    // MARK: The self-test's SDK

    /// Reuse a registered SDK; otherwise fetch the newest compatible one.
    /// The SDK registry is the commit point, so resumed setups reuse imports.
    func resolveSDK(
        for product: ToolchainProduct,
        swift: Bool,
        staging: URL,
        journal: JobJournal,
        reporter: TaskReporter,
        resumeStage: String = "downloading",
    ) async throws -> SDKRecord {
        do {
            return try Self.selfTestSDK(for: product, among: sdks.list(), swift: swift)
        } catch let refusal as ApelinError {
            guard supplier.hasEnabledSource else { throw refusal }
            _ = journal.enter("sdk")
            reporter.stage("sdk")
            try reporter.checkCancelled()
            let offers = supplier.offers()
            try reporter.checkCancelled()
            guard let offer = Self.preferredSDK(offers.offers, version: \.version, for: product, swift: swift) else {
                throw Self.noSourceOffers(refusal, offers: offers)
            }
            let record = try await fetchSDK(offer, for: product, swift: swift, staging: staging, reporter: reporter)
            if journal.enter(resumeStage) {
                reporter.stage(resumeStage)
            }
            return record
        }
    }

    /// The setup's `sdk` stage: imports `offer` through the supplier, its
    /// events relayed as the stage's progress, then picks the self-test's
    /// SDK among the registered ones again — the import registers what the
    /// tree's `SDKSettings.json` says, whatever the branch is called. The
    /// registry is the stage's record: a setup run again finds the SDK
    /// registered and does not fetch it twice. `staging` is the job's own,
    /// emptied before and after.
    private func fetchSDK(
        _ offer: SDKOffer,
        for product: ToolchainProduct,
        swift: Bool,
        staging: URL,
        reporter: TaskReporter,
    ) async throws -> SDKRecord {
        reporter.emit("sdkSource", .object([
            "source": .string(offer.source),
            "url": .string(offer.url),
            "branch": .string(offer.branch),
            "version": .string(offer.version),
        ]))
        try? FileManager.default.removeItem(at: staging)
        try layout.make(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try reporter.checkCancelled()
        let record = try await supplier.fetch(
            offer,
            staging: staging,
            hasSwiftToolchain: hasSwift,
            reporter: Self.sdkStageReporter(reporter),
        )
        try reporter.checkCancelled()
        try reporter.emit("sdkImported", .object(["sdk": JSONValue(encoding: record)]))
        do {
            return try Self.selfTestSDK(for: product, among: sdks.list(), swift: swift)
        } catch {
            throw ApelinError(
                .badRequest,
                "\(offer.source) \(offer.branch) holds iPhoneOS \(record.version), which Command Line Tools "
                    + "\(product.version) cannot self-test against (it reads up to \(product.newestSDK ?? "any version")); "
                    + "the SDK stays registered as \(record.id)",
            )
        }
    }

    /// The SDK import's events as the setup's `sdk` stage: each of its
    /// stages becomes the `phase` of a progress event, its progress goes
    /// through under `sdk` with the stage it came from as `phase` (bytes
    /// while it fetches, files while it inspects), and its warnings as
    /// they are. Cancelled with the setup.
    static func sdkStageReporter(_ reporter: TaskReporter) -> TaskReporter {
        TaskReporter(cancellation: reporter.cancellation) { kind, payload in
            switch kind {
            case "stage":
                guard let phase = payload?["stage"]?.stringValue else { return }
                reporter.emit("progress", .object([
                    "stage": .string("sdk"),
                    "phase": .string(phase),
                    "completed": .number(0),
                ]))
            case "progress":
                guard case var .object(fields)? = payload else { return }
                fields["phase"] = fields["stage"]
                fields["stage"] = .string("sdk")
                reporter.emit("progress", .object(fields))
            case "warning":
                reporter.emit(kind, payload)
            default:
                break
            }
        }
    }

    /// The refusal for a release no registered SDK fits, saying what the
    /// enabled sources had: nothing it reads (`badRequest`), or nothing
    /// because none of them could be read (`unavailable`).
    static func noSourceOffers(_ refusal: ApelinError, offers: SDKOffers) -> ApelinError {
        if offers.offers.isEmpty, !offers.problems.isEmpty {
            return ApelinError(
                .unavailable,
                refusal.message + " The SDK sources could not be read to fetch one: "
                    + offers.problems.joined(separator: "; "),
            )
        }
        let versions = Array(Set(offers.offers.map(\.version))).sorted(by: versionOrder)
        var message = refusal.message + " No enabled SDK source offers one either"
        message += versions.isEmpty ? "." : " (they offer \(versions.joined(separator: ", ")))."
        if !offers.problems.isEmpty {
            message += " Not read: " + offers.problems.joined(separator: "; ")
        }
        return ApelinError(.badRequest, message)
    }

    /// The newest of `items` whose version the release's tools read; with
    /// Swift, only those of the release's own iOS major. The first of equal
    /// versions wins, so a source listed earlier is preferred.
    static func newestReadable<Item>(
        _ items: [Item],
        version: (Item) -> String,
        for product: ToolchainProduct,
        swift: Bool,
    ) -> Item? {
        var readable = items.filter { product.reads(sdkVersion: version($0)) }
        if swift, let newest = product.newestSDK {
            readable = readable.filter { major(version($0)) == major(newest) }
        }
        return readable.reduce(nil) { best, item in
            guard let best else { return item }
            return versionOrder(version(best), version(item)) ? item : best
        }
    }

    static func major(_ version: String) -> String {
        version.split(separator: ".").first.map(String.init) ?? version
    }

    /// Prefer the release's reviewed pairing. A user can keep other SDKs
    /// installed; when the recommendation is unavailable, retain the newest
    /// compatible fallback instead of requiring another download.
    static func preferredSDK<Item>(
        _ items: [Item],
        version: (Item) -> String,
        for product: ToolchainProduct,
        swift: Bool,
    ) -> Item? {
        let recommendation = swift ? product.compatibility?.recommendedSwiftSDK : product.compatibility?.recommendedSDK
        if let recommendation, let match = items.first(where: { version($0) == recommendation }),
           newestReadable([match], version: version, for: product, swift: swift) != nil
        {
            return match
        }
        return newestReadable(items, version: version, for: product, swift: swift)
    }

    /// The SDK the self-test compiles against: the newest registered one the
    /// product's tools read (`ToolchainProduct.newestSDK`).
    /// With Swift, the SDK must be of the release's own iOS major: the
    /// compiler's macro plugins (`@Observable`) expand to code an older SDK's
    /// macro declarations do not cover (CLT 27.0 against the 18.5 SDK).
    static func selfTestSDK(
        for product: ToolchainProduct,
        among sdks: [SDKRecord],
        swift: Bool = false,
    ) throws -> SDKRecord {
        if let sdk = preferredSDK(sdks, version: \.version, for: product, swift: swift) {
            return sdk
        }
        if swift, let newest = product.newestSDK {
            let major = major(newest)
            throw ApelinError(
                .badRequest,
                "Swift with Command Line Tools \(product.version) needs an iPhoneOS \(major) SDK its tools read "
                    + "(up to \(newest)), whose macros match its compiler; the registered SDKs are "
                    + (sdks.isEmpty ? "none" : sdks.map(\.version).sorted(by: versionOrder).joined(separator: ", "))
                    + ". Import one first, or set the toolchain up without Swift.",
            )
        }
        let registered = sdks.map(\.version).sorted(by: versionOrder).joined(separator: ", ")
        let newest = product.newestSDK ?? "?"
        throw ApelinError(
            .badRequest,
            "Command Line Tools \(product.version) reads iPhoneOS SDKs up to \(newest), and the registered "
                + (sdks.isEmpty ? "list is empty" : "ones are \(registered)")
                + ". Import an iPhoneOS \(newest) SDK or an older one first: its self-test compiles against it.",
        )
    }
}
