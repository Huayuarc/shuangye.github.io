import ApelinCore
@testable import ApelinEnvironment
import ApelinProtocol
import ApelinToolchain
import Foundation
import XCTest

/// A remote source whose download is a real SDK import from a fixture.
private struct FixtureSDKSupplier: SDKSupplier {
    let layout: EnvironmentLayout
    let available: SDKOffers
    let log: EventLog
    var actualVersion: String?
    var beforeFetch: (@Sendable (TaskReporter) throws -> Void)?
    var hasEnabledSource: Bool {
        true
    }

    func offers() -> SDKOffers {
        log.append("list", nil)
        return available
    }

    func fetch(_ offer: SDKOffer, staging: URL, hasSwiftToolchain: Bool, reporter: TaskReporter) async throws -> SDKRecord {
        log.append("fetch", .string(offer.version))
        reporter.stage("fetching")
        reporter.progress("fetching", completed: 256, total: 512)
        try beforeFetch?(reporter)
        let version = actualVersion ?? offer.version
        let root = staging.appendingPathComponent("fixture.sdk")
        try SDKFixture.make(at: root, canonicalName: "iphoneos\(version)", version: version)
        return try await SDKManager(layout: layout).run(
            .inboxFolder(root, relative: "fixture.sdk"), staging: staging,
            hasSwiftToolchain: hasSwiftToolchain, reporter: reporter,
        )
    }
}

final class SDKResolutionTests: XCTestCase {
    private static let release = ToolchainProduct(
        productID: "001-00015", version: "15.3", url: "https://example.invalid/15.pkg", size: 1, newestSDK: "17.4",
    )

    private func home() throws -> TemporaryHome {
        let home = try TemporaryHome(self)
        try FileManager.default.createDirectory(atPath: home.layout.installRoot, withIntermediateDirectories: true)
        return home
    }

    private func offer(_ version: String) -> SDKOffer {
        SDKOffer(source: "Fixture", url: "https://example.invalid/sdks.git", branch: "sdk/iPhoneOS\(version)", version: version)
    }

    func testRecommendedPairingWinsWithoutBlockingOtherSDKs() {
        var release = Self.release
        release.compatibility = ToolchainCompatibility(recommendedSDK: "17.2", verifiedSDKs: ["17.2", "17.4"])
        let offers = [offer("17.4"), offer("17.2"), offer("18.5")]
        XCTAssertEqual(ToolchainService.preferredSDK(offers, version: \.version, for: release, swift: false)?.version, "17.2")
        XCTAssertEqual(ToolchainService.preferredSDK([offer("17.4")], version: \.version, for: release, swift: false)?.version, "17.4")
        release.compatibility?.recommendedSDK = "18.5"
        XCTAssertEqual(ToolchainService.preferredSDK(offers, version: \.version, for: release, swift: false)?.version, "17.4",
                       "a recommendation never bypasses the compiler's compatibility policy")
    }

    func testCompatibilityWireMatchesTheBackendAndSurvivesCatalog() async throws {
        for release in CommandLineToolsSupport.releases {
            let compatibility = try RetargetToolchainBackend.compatibility(release.compatibility)
            XCTAssertEqual(compatibility.recommendedSDK, release.recommendedSDK)
            XCTAssertEqual(compatibility.verifiedSDKs, release.verifiedSDKs)
            XCTAssertEqual(compatibility.swiftMinimumHostBasis, release.swiftSupport?.minimumHostBasis)
            XCTAssertEqual(try JSONValue(encoding: compatibility), try JSONValue(encoding: release.compatibility))
        }
        let home = try home()
        var release = Self.release
        release.compatibility = ToolchainCompatibility(recommendedSDK: "17.4")
        let catalog = try await ToolchainService(layout: home.layout, backend: FakeBackend(products: [release])).catalog()
        XCTAssertEqual(catalog.products.first?.compatibility, release.compatibility)
    }

    func testBranchNamesAndDisabledSources() {
        XCTAssertEqual(SDKOffer.version(ofBranch: "sdk/iPhoneOS18.2.1", prefix: "sdk/"), "18.2.1")
        for branch in ["main", "sdk/MacOSX15.0", "sdk/iPhoneOS", "sdk/iPhoneOS17..4", "sdk/iPhoneOS17.4-extra", "sdk/iPhoneOS17.4/sub"] {
            XCTAssertNil(SDKOffer.version(ofBranch: branch, prefix: "sdk/"), branch)
        }
        let statuses = [
            SDKSourceStatus(name: "Disabled", url: "https://example.invalid/disabled.git", enabled: false, branches: ["sdk/iPhoneOS99.0"]),
            SDKSourceStatus(name: "Enabled", url: "https://example.invalid/sdks.git", enabled: true, branches: ["main", "sdk/iPhoneOS17.4"]),
        ]
        XCTAssertEqual(SDKOffer.offers(from: statuses).map(\.version), ["17.4"])
    }

    func testMissingSDKDownloadsNewestCompatibleThenResumesWithoutFetchingAgain() async throws {
        let home = try home()
        let calls = EventLog()
        let supplier = FixtureSDKSupplier(layout: home.layout, available: SDKOffers(offers: [offer("17.2"), offer("18.5"), offer("17.4")]), log: calls)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let request = ToolchainSetupRequest(source: .appleCatalog(productID: Self.release.productID))
        let failing = ToolchainService(layout: home.layout, backend: FakeBackend(failPrepare: true, products: [Self.release]), supplier: supplier)
        let events = EventLog()
        do {
            _ = try await failing.setup(failing.prepare(request), taskID: TaskID("first"), installer: installer, reporter: events.reporter)
            XCTFail("the toolchain download fails after importing the SDK")
        } catch {}
        XCTAssertEqual(calls.last("fetch")?.stringValue, "17.4")
        XCTAssertEqual(SDKStore(layout: home.layout).list().map(\.version), ["17.4"])
        XCTAssertTrue(installer.installed.isEmpty)
        let transfer = try XCTUnwrap(events.events.first { $0.0 == "progress" && $0.1?["phase"]?.stringValue == "fetching" && $0.1?["total"] != nil }?.1)
        XCTAssertEqual(transfer["stage"]?.stringValue, "sdk")
        XCTAssertEqual(transfer["completed"]?.doubleValue, 256)
        XCTAssertEqual(transfer["total"]?.doubleValue, 512)

        let service = ToolchainService(layout: home.layout, backend: FakeBackend(products: [Self.release]), supplier: supplier)
        let record = try await service.setup(service.prepare(request), taskID: TaskID("resumed"), installer: installer, reporter: .silent)
        XCTAssertEqual(record.selfTestSDK, "17.4")
        XCTAssertEqual(record.components.first?.selfCheckPassed, true)
        XCTAssertEqual(calls.kinds, ["list", "fetch"], "the registered SDK is reused without reading the remote again")
    }

    func testSwiftSelectsTheSameSDKMajorAndRejectsAMislabeledDownload() async throws {
        let home = try home()
        var release = Self.release
        release.version = "27.0"
        release.newestSDK = "27"
        let offers = [offer("18.5"), offer("27.0"), offer("27.1"), offer("28.0")]
        XCTAssertEqual(ToolchainService.newestReadable(offers, version: \.version, for: release, swift: true)?.version, "27.1")
        XCTAssertNil(ToolchainService.newestReadable([offer("18.5")], version: \.version, for: release, swift: true))
        let supplier = FixtureSDKSupplier(layout: home.layout, available: SDKOffers(offers: offers), log: EventLog(), actualVersion: "18.5")
        let service = ToolchainService(layout: home.layout, backend: FakeBackend(products: [release]), supplier: supplier)
        let request = ToolchainSetupRequest(components: [.c, .swift])
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        do {
            _ = try await service.setup(service.prepare(request), taskID: TaskID("wrong"), installer: installer, reporter: .silent)
            XCTFail("branch names cannot override SDKSettings.json")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
            XCTAssertTrue(error.message.contains("holds iPhoneOS 18.5"), error.message)
        }
        XCTAssertTrue(installer.installed.isEmpty)
        XCTAssertTrue(service.status(activeTasks: []).toolchains.isEmpty)
    }

    func testNoCompatibleSourceAndOfflineSourcesExplainTheFailureBeforeInstalling() async throws {
        for (available, expected) in [
            (SDKOffers(offers: [offer("18.5")]), ApelinError.Code.badRequest),
            (SDKOffers(problems: ["Fixture: offline"]), ApelinError.Code.unavailable),
        ] {
            let home = try home()
            let calls = EventLog()
            let supplier = FixtureSDKSupplier(layout: home.layout, available: available, log: calls)
            let service = ToolchainService(layout: home.layout, backend: FakeBackend(products: [Self.release]), supplier: supplier)
            let installer = FakeInstaller(installRoot: home.layout.installRoot)
            do {
                _ = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("missing"), installer: installer, reporter: .silent)
                XCTFail("there is no SDK the tools can read")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, expected)
                XCTAssertTrue(error.message.contains("up to 17.4"), error.message)
            }
            XCTAssertEqual(calls.kinds, ["list"])
            XCTAssertTrue(installer.installed.isEmpty)
        }
    }

    func testUnavailableSwiftDoesNotFetchAnSDK() async throws {
        let home = try home()
        let calls = EventLog()
        var release = Self.release
        release.supportsSwift = false
        let supplier = FixtureSDKSupplier(layout: home.layout, available: SDKOffers(offers: [offer("17.4")]), log: calls)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend(products: [release]), supplier: supplier)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let request = ToolchainSetupRequest(components: [.c, .swift])
        do {
            _ = try await service.setup(service.prepare(request), taskID: TaskID("unsupported"), installer: installer, reporter: .silent)
            XCTFail("Swift is unavailable on this host or with this release")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
            XCTAssertTrue(error.message.contains("Swift is not available"), error.message)
        }
        XCTAssertTrue(calls.kinds.isEmpty, "unsupported Swift does not download an SDK first")
        XCTAssertTrue(installer.installed.isEmpty)
    }

    func testCancellationDuringSDKFetchCleansStagingAndDoesNotInstall() async throws {
        let home = try home()
        let supplier = FixtureSDKSupplier(
            layout: home.layout, available: SDKOffers(offers: [offer("17.4")]), log: EventLog(),
            beforeFetch: { reporter in
                reporter.cancellation.cancel()
                try reporter.checkCancelled()
            },
        )
        let service = ToolchainService(layout: home.layout, backend: FakeBackend(products: [Self.release]), supplier: supplier)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        do {
            _ = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("cancel"), installer: installer, reporter: TaskReporter { _, _ in })
            XCTFail("the download was cancelled")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertTrue(installer.installed.isEmpty)
        XCTAssertTrue(SDKStore(layout: home.layout).list().isEmpty)
        let key = ToolchainService.jobKey(product: Self.release, components: [.c])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.layout.toolchainJobs.appendingPathComponent(key).path))
    }
}
