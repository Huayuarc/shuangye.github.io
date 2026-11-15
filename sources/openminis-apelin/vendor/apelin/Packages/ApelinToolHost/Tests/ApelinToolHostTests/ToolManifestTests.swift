@testable import ApelinToolHost
import Darwin
import Foundation
import XCTest

/// Manifest validation against a scratch install root. Files there belong to
/// the test's user, so the policy asks for that owner instead of root.
final class ToolManifestTests: XCTestCase {
    private var root = ""
    private let id = "wiki.qaq.apelin.agent-tools.sample"
    private var policy: ToolManifestPolicy {
        ToolManifestPolicy(requiredOwner: getuid())
    }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "apelin-tool-manifest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/usr/libexec/apelin/agent-tools", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/usr/share/apelin/agent-tools/\(id)/licenses", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: ToolHostClientTests.fakeExecutable, toPath: root + "/usr/libexec/apelin/agent-tools/sample")
        chmod(root + "/usr/libexec/apelin/agent-tools/sample", 0o755)
        FileManager.default.createFile(atPath: root + "/usr/share/apelin/agent-tools/\(id)/licenses/LICENSE", contents: Data("MIT".utf8))
        try writeManifest(manifest())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func manifest(executable: String = "usr/libexec/apelin/agent-tools/sample") -> ToolManifest {
        ToolManifest(id: id, name: "Sample", version: "1.0.0", license: "MIT", licenseFiles: ["licenses/LICENSE"],
                     executable: executable,
                     tools: [ToolDescriptor(name: "echo", description: "Echo.", parameters: ["type": "object"], risk: .readOnly)])
    }

    private func writeManifest(_ manifest: ToolManifest, id: String? = nil) throws {
        let data = try JSONEncoder().encode(manifest)
        let directory = root + "/usr/share/apelin/agent-tools/\(id ?? self.id)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory + "/manifest.json"))
        chmod(directory + "/manifest.json", 0o644)
    }

    func testValidManifest() throws {
        let validated = try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy)
        XCTAssertEqual(validated.manifest.tools.map(\.name), ["echo"])
        XCTAssertEqual(validated.executablePath, try CanonicalPath.resolve(root + "/usr/libexec/apelin/agent-tools/sample"))
        XCTAssertEqual(validated.licensePaths.count, 1)
        XCTAssertNoThrow(try ToolManifestValidator.recheckExecutable(validated, policy: policy))
    }

    func testRootOwnershipIsRequiredByDefault() {
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: id)) { error in
            XCTAssertTrue("\(error)".contains("owned by uid"), "\(error)")
        }
    }

    func testExecutableEscapingTheRootIsRefused() throws {
        try writeManifest(manifest(executable: "../../bin/ls"))
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy))

        symlink("/bin/ls", root + "/usr/libexec/apelin/agent-tools/escape")
        try writeManifest(manifest(executable: "usr/libexec/apelin/agent-tools/escape"))
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy)) { error in
            XCTAssertTrue("\(error)".contains("resolves outside"), "\(error)")
        }

        try writeManifest(manifest(executable: "/bin/ls"))
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy))
    }

    func testWritableExecutableIsRefused() throws {
        chmod(root + "/usr/libexec/apelin/agent-tools/sample", 0o775)
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy)) { error in
            XCTAssertTrue("\(error)".contains("writable by group or others"), "\(error)")
        }
    }

    func testRecheckCatchesAChangeAfterValidation() throws {
        let validated = try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy)
        chmod(root + "/usr/libexec/apelin/agent-tools/sample", 0o777)
        XCTAssertThrowsError(try ToolManifestValidator.recheckExecutable(validated, policy: policy))
    }

    func testFieldChecks() throws {
        var duplicate = manifest()
        duplicate.tools.append(duplicate.tools[0])
        try writeManifest(duplicate)
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy))

        var badSchema = manifest()
        badSchema.tools[0].parameters = ["type": "string"]
        try writeManifest(badSchema)
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy))

        var wrongID = manifest()
        wrongID.id = "wiki.qaq.other"
        try writeManifest(wrongID)
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy))

        var future = manifest()
        future.protocolVersions = [42]
        try writeManifest(future)
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: id, policy: policy))

        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: "../escape", policy: policy))
        XCTAssertThrowsError(try ToolManifestValidator.validate(installRoot: root, id: "bad\u{0}id", policy: policy))
    }

    func testDiscoveryIsolatesABadManifest() throws {
        var broken = manifest()
        broken.id = "wiki.qaq.apelin.agent-tools.broken"
        broken.executable = "usr/libexec/missing"
        try writeManifest(broken, id: "wiki.qaq.apelin.agent-tools.broken")
        let found = ToolManifestValidator.discover(installRoot: root, policy: policy)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.compactMap { try? $0.get().manifest.id }, [id])
        XCTAssertEqual(found.compactMap {
            if case let .failure(error) = $0 {
                error.id
            } else {
                nil
            }
        },
        ["wiki.qaq.apelin.agent-tools.broken"])
    }

    func testClientStartsFromAValidatedManifest() async throws {
        var fake = manifest()
        fake.id = "wiki.qaq.apelin.agent-tools.fake"
        fake.licenseFiles = nil
        try writeManifest(fake, id: fake.id)
        let validated = try ToolManifestValidator.validate(installRoot: root, id: fake.id, policy: policy)
        let client = ToolHostClient(validated: validated, policy: policy)
        let hello = try await client.start()
        XCTAssertEqual(hello.peer.name, fake.id)
        let outcome = await client.call(tool: "echo", arguments: ["text": "from the manifest"])
        XCTAssertEqual(outcome.result?.text, "from the manifest")
        await client.terminate()
    }

    func testCanonicalPathHelpers() {
        XCTAssertTrue(CanonicalPath.isInside("/var/jb/usr/bin", root: "/var/jb"))
        XCTAssertTrue(CanonicalPath.isInside("/var/jb", root: "/var/jb"))
        XCTAssertFalse(CanonicalPath.isInside("/var/jbx/usr", root: "/var/jb"))
        XCTAssertTrue(CanonicalPath.isInside("/anything", root: "/"))
        XCTAssertTrue(CanonicalPath.isPlainRelative("usr/libexec/tool"))
        XCTAssertFalse(CanonicalPath.isPlainRelative("usr/../tool"))
        XCTAssertFalse(CanonicalPath.isPlainRelative("/usr/tool"))
        XCTAssertFalse(CanonicalPath.isPlainRelative("usr//tool"))
        XCTAssertThrowsError(try CanonicalPath.resolve("/tmp\u{0}/x"))
    }
}
