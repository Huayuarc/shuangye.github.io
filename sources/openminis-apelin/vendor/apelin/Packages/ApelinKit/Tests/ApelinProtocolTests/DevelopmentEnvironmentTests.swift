import ApelinCore
@testable import ApelinProtocol
import Foundation
import XCTest

/// The toolchain and SDK shell_run and the terminal compile with, chosen
/// from apelin-environment's registries the way `projectCreate` binds them.
final class DevelopmentEnvironmentTests: XCTestCase {
    private var home: URL!
    private var folder: DataFolder!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apelin-development-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: CanonicalPath.resolve(base.path)!, isDirectory: true)
        folder = DataFolder(home: home.path)
        try FileManager.default.createDirectory(at: folder.sdkRegistry, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.toolchains, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func toolchain(_ id: String, newestSDK: String?, layout: String = ToolchainLayout.flatBin) throws -> ToolchainRecord {
        let path = home.appendingPathComponent("toolchains/\(id)")
        try FileManager.default.createDirectory(at: path.appendingPathComponent(layout), withIntermediateDirectories: true)
        return ToolchainRecord(
            id: id,
            version: "27.0",
            components: [ToolchainComponent(kind: .c, selfCheckPassed: true)],
            path: path.path,
            installationID: "installation-\(id)",
            origin: "082-00000 https://user:token@example.invalid/pkg",
            newestSDK: newestSDK,
        )
    }

    private func sdk(_ id: String, version: String) throws -> SDKRecord {
        let path = folder.sdks.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return SDKRecord(id: id, canonicalName: id, version: version, path: path.path, digest: "d")
    }

    private func writeRegistry(_ toolchains: [ToolchainRecord], defaultID: String?, sdks: [SDKRecord]) throws {
        var file: [String: JSONValue] = try ["toolchains": JSONValue(encoding: toolchains)]
        if let defaultID {
            file["defaultID"] = .string(defaultID)
        }
        try JSONCoding.encode(JSONValue.object(file)).write(to: folder.toolchainRegistry)
        for record in sdks {
            try JSONCoding.encode(record).write(to: folder.sdkRegistry.appendingPathComponent("\(record.id).json"))
        }
    }

    private func project(_ manifest: String) throws -> String {
        let project = folder.projects.appendingPathComponent("Hello")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: project.appendingPathComponent("apelin-project.json"))
        return project.path
    }

    func testTheProjectsBindingWinsAndTheVariablesNameIt() throws {
        let old = try toolchain("clt-16.4", newestSDK: "18.5")
        let new = try toolchain("clt-27.0", newestSDK: "27")
        let bound = try sdk("iphoneos18.5-aaaa", version: "18.5")
        let newest = try sdk("iphoneos27.0-bbbb", version: "27.0")
        try writeRegistry([new, old], defaultID: new.id, sdks: [newest, bound])
        let project = try project("""
        {"deploymentTarget":"15.0","environment":{"toolchain":{"id":"clt-16.4"},"sdk":{"id":"iphoneos18.5-aaaa"}}}
        """)

        let environment = DevelopmentEnvironment.prepared(home: home.path, projectDirectory: project)
        XCTAssertEqual(environment.toolchain?.record.id, old.id)
        XCTAssertEqual(environment.toolchain?.source, .project)
        XCTAssertEqual(environment.sdk?.record.id, bound.id)
        XCTAssertEqual(environment.sdk?.source, .project)
        XCTAssertEqual(environment.deploymentTarget, "15.0")

        let bin = try XCTUnwrap(old.path) + "/usr/bin"
        let variables = environment.variables(basePath: ["/jb/usr/bin", bin, "/usr/bin"])
        XCTAssertEqual(variables, [
            "PATH": "\(bin):/jb/usr/bin:/usr/bin",
            "SDKROOT": bound.path,
            "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
            "APELIN_TOOLCHAIN_BIN": bin,
        ], "the toolchain once, first; nothing else")
        XCTAssertFalse(environment.entries(basePath: []).joined().contains("token"), "no record field beyond paths reaches the environment")
        XCTAssertEqual(environment.entries(basePath: []).first, "APELIN_TOOLCHAIN_BIN=\(bin)", "entries are sorted")
    }

    func testWithoutABindingTheDefaultToolchainAndTheNewestSDKItReads() throws {
        let old = try toolchain("clt-16.4", newestSDK: "18.5")
        let new = try toolchain("clt-27.0", newestSDK: "27")
        let sdks = try [sdk("iphoneos17.0-cccc", version: "17.0"), sdk("iphoneos18.5-aaaa", version: "18.5"), sdk("iphoneos27.0-bbbb", version: "27.0")]
        try writeRegistry([new, old], defaultID: old.id, sdks: sdks)

        let general = DevelopmentEnvironment.prepared(home: home.path, projectDirectory: nil)
        XCTAssertEqual(general.toolchain?.record.id, old.id)
        XCTAssertEqual(general.toolchain?.source, .fallback)
        XCTAssertEqual(general.sdk?.record.id, "iphoneos18.5-aaaa", "the newest the toolchain reads, not the newest")
        XCTAssertEqual(general.deploymentTarget, DevelopmentEnvironment.defaultDeploymentTarget)

        // A binding to what is not registered falls back the same way, and a
        // deployment target that is not a version is not passed on.
        let project = try project(#"{"deploymentTarget":"16.0;x","environment":{"toolchain":{"id":"gone"},"sdk":{"id":"gone"}}}"#)
        let unbound = DevelopmentEnvironment.prepared(home: home.path, projectDirectory: project)
        XCTAssertEqual(unbound.toolchain?.record.id, old.id)
        XCTAssertEqual(unbound.sdk?.record.id, "iphoneos18.5-aaaa")
        XCTAssertEqual(unbound.deploymentTarget, "16.0")
    }

    func testAToolchainWhoseFolderIsGoneIsPassedOverAndTheCLTLayoutIsFound() throws {
        var missing = try toolchain("clt-gone", newestSDK: nil)
        missing.path = home.appendingPathComponent("nowhere").path
        let layout = try toolchain("clt-layout", newestSDK: nil, layout: ToolchainLayout.commandLineToolsBin)
        try writeRegistry([missing, layout], defaultID: missing.id, sdks: [])

        let environment = DevelopmentEnvironment.prepared(home: home.path, projectDirectory: nil)
        XCTAssertEqual(environment.toolchain?.record.id, layout.id)
        XCTAssertEqual(environment.toolchain?.binDirectory, try XCTUnwrap(layout.path) + "/" + ToolchainLayout.commandLineToolsBin)
        XCTAssertNil(environment.sdk)
        let variables = environment.variables(basePath: ["/usr/bin"])
        XCTAssertNil(variables["SDKROOT"])
        XCTAssertNil(variables["IPHONEOS_DEPLOYMENT_TARGET"], "no deployment target without an SDK to pair it with")
    }

    func testNothingRegisteredLeavesThePathAsItWas() {
        let environment = DevelopmentEnvironment.prepared(home: home.path, projectDirectory: nil)
        XCTAssertNil(environment.toolchain)
        XCTAssertEqual(environment.variables(basePath: ["/a", "/b"]), ["PATH": "/a:/b"])
    }

    func testAPathThatWouldSplitPATHIsRefused() throws {
        let record = try toolchain("clt:colon", newestSDK: nil)
        try writeRegistry([record], defaultID: record.id, sdks: [])
        XCTAssertNil(DevelopmentEnvironment.prepared(home: home.path, projectDirectory: nil).toolchain)
    }

    /// The session host reads these as root from a folder mobile owns.
    func testRegistriesAreReadOnlyFromInsideTheDataFolderAndNotThroughALink() throws {
        let record = try toolchain("clt-27.0", newestSDK: nil)
        let outside = home.appendingPathComponent("outside.json")
        try JSONCoding.encode(JSONValue.object(["toolchains": JSONValue(encoding: [record])])).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.toolchainRegistry, withDestinationURL: outside)
        XCTAssertTrue(RegisteredEnvironment.read(folder).toolchains.isEmpty, "a registry that is a link is not read")

        try FileManager.default.removeItem(at: folder.toolchainRegistry)
        try FileManager.default.removeItem(at: folder.toolchains)
        let elsewhere = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: outside, to: elsewhere.appendingPathComponent("registry.json"))
        try FileManager.default.createSymbolicLink(at: folder.toolchains, withDestinationURL: elsewhere)
        XCTAssertTrue(RegisteredEnvironment.read(folder).toolchains.isEmpty, "a folder that leads out of the data folder is not read")

        try FileManager.default.removeItem(at: folder.toolchains)
        try FileManager.default.createDirectory(at: folder.toolchains, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: outside, to: folder.toolchainRegistry)
        XCTAssertEqual(RegisteredEnvironment.read(folder).toolchains.map(\.id), ["clt-27.0"])
        XCTAssertEqual(RegisteredEnvironment.read(folder).defaultToolchainID, "clt-27.0", "the first is the default when none is named")
    }

    func testSDKsAreReadNewestFirstAndUnreadableRecordsLeftOut() throws {
        let sdks = try [sdk("b-17", version: "17.0"), sdk("a-27", version: "27.0"), sdk("c-9", version: "9.3")]
        try writeRegistry([], defaultID: nil, sdks: sdks)
        try Data("not json".utf8).write(to: folder.sdkRegistry.appendingPathComponent("broken.json"))
        XCTAssertEqual(RegisteredEnvironment.read(folder).sdks.map(\.id), ["a-27", "b-17", "c-9"])
    }

    func testTheBootstrapIsReadFromWhereMobilesHomeIs() {
        XCTAssertEqual(BuildBootstrap.resolve(installRoot: "/var/jb", home: "/var/mobile"), .rootless)
        XCTAssertEqual(BuildBootstrap.resolve(installRoot: "/private/preboot/x/jb-1/", home: "/private/preboot/x/jb-1/var/mobile"), .roothide)
        XCTAssertEqual(BuildBootstrap.resolve(installRoot: "", home: "/var/mobile"), .rootless)
    }
}
