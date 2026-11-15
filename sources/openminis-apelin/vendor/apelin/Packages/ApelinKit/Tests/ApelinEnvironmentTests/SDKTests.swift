import ApelinCore
@testable import ApelinEnvironment
import ApelinProtocol
import Foundation
import XCTest

final class SDKIdentificationTests: XCTestCase {
    func testIdentifiesFromSDKSettingsAndFoundationTBD() throws {
        let home = try TemporaryHome(self)
        // The folder name lies, as Theos's iPhoneOS16.5.sdk does.
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("iPhoneOS1.0.sdk"))
        let identity = try SDKInspector().identify(root)
        XCTAssertEqual(identity.canonicalName, "iphoneos99.0")
        XCTAssertEqual(identity.version, "99.0")
        XCTAssertEqual(identity.targets, ["arm64e-ios", "arm64e.x1-ios"])
        XCTAssertEqual(identity.swiftCompilerVersion, "Apple Swift version 9.9 (fixture)")
        XCTAssertTrue(identity.warnings.contains { $0.contains("arm64-ios") }, "\(identity.warnings)")
    }

    func testReadsJSONTBD() {
        let text = #"{"tapi_tbd_version": 5, "target_info": [{"target": "arm64-ios"}, {"target": "arm64e-ios"}]}"#
        XCTAssertEqual(SDKInspector.tbdTargets(text), ["arm64-ios", "arm64e-ios"])
    }

    /// A v3 TBD names `archs` and one `platform` instead of targets, as the
    /// community iPhoneOS26.4.sdk's Foundation.tbd does; its import was
    /// refused on the iOS 26.4 vphone (2026-10-17).
    func testReadsV3TBD() {
        let text = """
        --- !tapi-tbd-v3
        archs:                 [ armv7, armv7s, arm64, arm64e ]
        platform:              ios
        flags:                 [ flat_namespace ]
        install-name:          /System/Library/Frameworks/Foundation.framework/Foundation
        exports:
          - archs:                [ arm64, arm64e ]
            symbols:              [ _NSLog ]
        """
        XCTAssertEqual(SDKInspector.tbdTargets(text), ["armv7-ios", "armv7s-ios", "arm64-ios", "arm64e-ios"])
    }

    func testRefusesSomethingThatIsNotAnIPhoneOSSDK() throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("MacOSX.sdk"), canonicalName: "macosx15.0")
        XCTAssertThrowsError(try SDKInspector().identify(root)) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("SDKSettings.json"))
        XCTAssertThrowsError(try SDKInspector().locateRoot(in: home.home))
    }

    func testInspectionAcceptsLinkInputs() throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("SDK"))
        let inspection = try SDKInspector().inspect(root)
        XCTAssertEqual(inspection.digest.count, 64)
        XCTAssertGreaterThanOrEqual(inspection.fileCount, 5)
        // Same content, same digest.
        XCTAssertEqual(try SDKInspector().inspect(root).digest, inspection.digest)
    }

    /// Files are checked and hashed on several cores: the digest is the one
    /// the tree's lines give in walk order, whatever core finished first, and
    /// with several refused files the refusal names the first in walk order.
    func testParallelInspectionIsOrderIndependent() throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("SDK"))
        let many = root.appendingPathComponent("usr/include/many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0 ..< 300 {
            try Data("int value\(index) = \(index);\n".utf8).write(to: many.appendingPathComponent(String(format: "h%03d.h", index)))
        }
        let digests = try (0 ..< 5).map { _ in try SDKInspector().inspect(root).digest }
        XCTAssertEqual(Set(digests).count, 1)
        XCTAssertGreaterThanOrEqual(try SDKInspector().inspect(root).fileCount, 300)

        try MachOFixture.executable.write(to: many.appendingPathComponent("h100.h"))
        try MachOFixture.executable.write(to: many.appendingPathComponent("h250.h"))
        for _ in 0 ..< 5 {
            XCTAssertThrowsError(try SDKInspector().inspect(root)) { error in
                XCTAssertTrue("\(error)".contains("h100.h"), "\(error)")
            }
        }
    }

    func testRefusesAnExecutable() throws {
        try assertRefused(MachOFixture.executable, contains: "MH_EXECUTE")
    }

    func testRefusesAnExecutableSliceOfAFatFile() throws {
        let fat = MachOFixture.fat([(MachOFixture.arm64, MachOFixture.dylib), (MachOFixture.x86_64, MachOFixture.thin(fileType: 2, cpu: MachOFixture.x86_64))])
        try assertRefused(fat, contains: "MH_EXECUTE")
    }

    func testAcceptsAFatDylib() throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("SDK"))
        let fat = MachOFixture.fat([(MachOFixture.arm64, MachOFixture.dylib), (MachOFixture.x86_64, MachOFixture.thin(fileType: 6, cpu: MachOFixture.x86_64))])
        try fat.write(to: root.appendingPathComponent("usr/lib/libfat.dylib"))
        XCTAssertNoThrow(try SDKInspector().inspect(root))
    }

    /// The iOS 27 SDK's CoreImage.framework carries a fat `.metallib`: one
    /// Metal library (`MTLB`) per GPU family, CPU type 0x01000017.
    func testAcceptsAFatMetalLibrary() throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("SDK"))
        let library = Data("MTLB".utf8) + Data(count: 60)
        let fat = MachOFixture.fat([(0x0100_0017, library), (0x0100_0017, library)])
        try fat.write(to: root.appendingPathComponent("usr/lib/Kernels.metallib"))
        XCTAssertNoThrow(try SDKInspector().inspect(root))
    }

    func testRefusesAnExecutableInsideAStaticArchive() throws {
        try assertRefused(MachOFixture.archive([("a.o", MachOFixture.object), ("tool", MachOFixture.executable)]), contains: "MH_EXECUTE")
    }

    func testRefusesAnExecutableInsideAFatStaticArchive() throws {
        let archive = MachOFixture.archive([("tool", MachOFixture.executable)])
        try assertRefused(MachOFixture.fat([(MachOFixture.arm64, archive)]), contains: "MH_EXECUTE")
    }

    func testRefusesABundle() throws {
        try assertRefused(MachOFixture.bundle, contains: "MH_BUNDLE")
    }

    func testExecutableBitIsNotTheTest() throws {
        // A shell script with the executable bit is not Mach-O and passes;
        // an executable without the bit is refused above.
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("SDK"))
        let script = root.appendingPathComponent("usr/lib/helper.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        XCTAssertNoThrow(try SDKInspector().inspect(root))
    }

    func testRefusesALinkOutOfTheSDK() throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("SDK"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("usr/lib/escape").path, withDestinationPath: "/etc")
        XCTAssertThrowsError(try SDKInspector().inspect(root)) { XCTAssertEqual(($0 as? ApelinError)?.code, .denied) }
    }

    func testRefusesARelativeLinkClimbingOut() throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("SDK"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("usr/lib/up").path, withDestinationPath: "../../../nowhere")
        XCTAssertThrowsError(try SDKInspector().inspect(root)) { XCTAssertEqual(($0 as? ApelinError)?.code, .denied) }
    }

    func testDanglingLinkInsideIsAWarning() throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("SDK"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("usr/lib/missing.dylib").path, withDestinationPath: "libnothing.dylib")
        let inspection = try SDKInspector().inspect(root)
        XCTAssertTrue(inspection.warnings.contains { $0.contains("lead nowhere") })
    }

    private func assertRefused(_ data: Data, contains needle: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.home.appendingPathComponent("SDK"))
        // No executable bit: the Mach-O type decides.
        try data.write(to: root.appendingPathComponent("usr/lib/suspect"))
        XCTAssertThrowsError(try SDKInspector().inspect(root), file: file, line: line) { error in
            XCTAssertEqual((error as? ApelinError)?.code, .denied, file: file, line: line)
            XCTAssertTrue(String(describing: error).contains(needle), "\(error)", file: file, line: line)
        }
    }
}

final class SDKImportTests: XCTestCase {
    func testImportsAFolderFromTheInboxAndRegistersIt() async throws {
        let home = try TemporaryHome(self)
        try SDKFixture.make(at: home.inbox.appendingPathComponent("iPhoneOS99.0.sdk"))
        let manager = SDKManager(layout: home.layout)
        let record = try await importing(manager, .inbox(path: "iPhoneOS99.0.sdk"), home: home)

        XCTAssertTrue(record.id.hasPrefix("iphoneos99.0-"))
        XCTAssertEqual(record.id.count, "iphoneos99.0-".count + 8)
        XCTAssertEqual(record.digest?.prefix(8), record.id.suffix(8)[...])
        XCTAssertEqual(record.origin, "inbox iPhoneOS99.0.sdk")
        XCTAssertEqual(record.path, home.layout.sdks.appendingPathComponent(record.id).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + "/SDKSettings.json"))
        XCTAssertEqual(manager.list(SDKListRequest()).sdks, [record])
        // The inbox copy is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.inbox.appendingPathComponent("iPhoneOS99.0.sdk/SDKSettings.json").path))

        // The same SDK again is the same registration.
        let again = try await importing(manager, .inbox(path: "iPhoneOS99.0.sdk"), home: home)
        XCTAssertEqual(again, record)
        XCTAssertEqual(manager.list(SDKListRequest()).sdks.count, 1)
    }

    func testImportsArchives() async throws {
        for kind in [ArchiveFixture.Kind.tarXZ, .tarZstd, .zip] {
            let home = try TemporaryHome(self)
            let source = try SDKFixture.make(at: home.home.appendingPathComponent("build/iPhoneOS99.0.sdk"))
            let name = "sdk-\(kind)"
            try ArchiveFixture.write(ArchiveFixture.entries(of: source, prefix: "iPhoneOS99.0.sdk"), kind: kind, to: home.inbox.appendingPathComponent(name))
            let manager = SDKManager(layout: home.layout)
            let record = try await importing(manager, .inbox(path: name), home: home)
            XCTAssertEqual(record.canonicalName, "iphoneos99.0", "\(kind)")
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: record.path + "/usr/lib/libfixture.1.dylib"),
                "libfixture.dylib",
            )
        }
    }

    func testImportsAnArchiveDescriptor() async throws {
        let home = try TemporaryHome(self)
        let source = try SDKFixture.make(at: home.home.appendingPathComponent("build/iPhoneOS99.0.sdk"))
        let archive = home.home.appendingPathComponent("sdk.tar.zst")
        try ArchiveFixture.write(ArchiveFixture.entries(of: source, prefix: "iPhoneOS99.0.sdk"), kind: .tarZstd, to: archive)
        let descriptor = OwnedDescriptor(adopting: open(archive.path, O_RDONLY))
        let manager = SDKManager(layout: home.layout)
        let prepared = try manager.prepare(SDKImportRequest(source: .file(DescriptorSlot(index: 0))), descriptors: [descriptor])
        let staging = try home.layout.makeStaging("descriptor")
        let record = try await manager.run(prepared, staging: staging, hasSwiftToolchain: false, reporter: .silent)
        XCTAssertEqual(record.origin, "file")
        XCTAssertTrue(record.warnings.contains { $0.contains("Swift") })
    }

    /// A download's origin is in every sdkList reply and every .apesdk, so
    /// it keeps no user, password, query or fragment, where a token rides.
    func testADownloadsOriginCarriesNoCredentials() async throws {
        let home = try TemporaryHome(self)
        let source = try SDKFixture.make(at: home.home.appendingPathComponent("build/iPhoneOS99.0.sdk"))
        let archive = home.home.appendingPathComponent("sdk.tar.zst")
        try ArchiveFixture.write(ArchiveFixture.entries(of: source, prefix: "iPhoneOS99.0.sdk"), kind: .tarZstd, to: archive)
        ArchiveURLStub.body = try Data(contentsOf: archive)
        URLProtocol.registerClass(ArchiveURLStub.self)
        defer { URLProtocol.unregisterClass(ArchiveURLStub.self) }
        let manager = SDKManager(layout: home.layout)
        let url = "https://user:secret@sdk.example.invalid:8443/sdks/iPhoneOS99.0.tar.zst?token=hunter2#part"
        let record = try await importing(manager, .url(url), home: home)
        XCTAssertEqual(record.origin, "url https://sdk.example.invalid:8443/sdks/iPhoneOS99.0.tar.zst")
    }

    func testArchiveEscapesAreRefused() throws {
        let cases: [[ArchiveFixture.Entry]] = [
            [ArchiveFixture.Entry(name: "../escape", data: Data("x".utf8))],
            [ArchiveFixture.Entry(name: "/etc/escape", data: Data("x".utf8))],
            [ArchiveFixture.Entry(name: "sdk/../../escape", data: Data("x".utf8))],
            // A link first, then a file through it.
            [ArchiveFixture.Entry(name: "link", symlink: "/tmp"), ArchiveFixture.Entry(name: "link/escape", data: Data("x".utf8))],
            [ArchiveFixture.Entry(name: "twice", data: Data("a".utf8)), ArchiveFixture.Entry(name: "twice", data: Data("b".utf8))],
        ]
        for (index, entries) in cases.enumerated() {
            let home = try TemporaryHome(self)
            let archive = home.home.appendingPathComponent("evil-\(index).tar.xz")
            try ArchiveFixture.write(entries, kind: .tarXZ, to: archive)
            let destination = try home.layout.makeStaging("evil-\(index)")
            XCTAssertThrowsError(try ArchiveExtractor().extract(.path(archive.path), into: destination), "case \(index)") { error in
                XCTAssertEqual((error as? ApelinError)?.code, .badRequest, "case \(index): \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.home.appendingPathComponent("escape").path), "case \(index)")
        }
    }

    func testArchiveLimits() throws {
        let home = try TemporaryHome(self)
        let archive = home.home.appendingPathComponent("big.tar.xz")
        try ArchiveFixture.write([ArchiveFixture.Entry(name: "big", data: Data(count: 4096))], kind: .tarXZ, to: archive)
        let destination = try home.layout.makeStaging("big")
        let extractor = ArchiveExtractor(limits: .init(maximumBytes: 1024))
        XCTAssertThrowsError(try extractor.extract(.path(archive.path), into: destination))
    }

    func testInboxPathsStayInTheInbox() throws {
        let home = try TemporaryHome(self)
        _ = home.inbox
        let manager = SDKManager(layout: home.layout)
        try FileManager.default.createDirectory(at: home.layout.sdks, withIntermediateDirectories: true)
        for path in ["../SDKs", home.layout.sdks.path, "", "."] {
            XCTAssertThrowsError(try manager.prepare(SDKImportRequest(source: .inbox(path: path)), descriptors: []), path.debugDescription)
        }
        // A link in the inbox leading out is judged by where it leads.
        try FileManager.default.createSymbolicLink(atPath: home.inbox.appendingPathComponent("out").path, withDestinationPath: home.layout.sdks.path)
        XCTAssertThrowsError(try manager.prepare(SDKImportRequest(source: .inbox(path: "out")), descriptors: [])) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .denied)
        }
    }

    func testOnlyHTTPSSources() {
        let manager = SDKManager(layout: EnvironmentLayout(data: DataFolder(home: "/nonexistent"), installRoot: "/", home: "/nonexistent"))
        for source in [SDKSource.repository(url: "git@github.com:a/b.git", branch: "sdk/x"), .repository(url: "http://example.com/a.git", branch: "x"), .url("file:///etc/passwd"), .url("http://example.com/a.zip")] {
            XCTAssertThrowsError(try manager.prepare(SDKImportRequest(source: source), descriptors: []), "\(source)")
        }
    }

    func testAnExecutableInTheInboxFolderFailsTheImportAndLeavesNothing() async throws {
        let home = try TemporaryHome(self)
        let root = try SDKFixture.make(at: home.inbox.appendingPathComponent("Bad.sdk"))
        try MachOFixture.executable.write(to: root.appendingPathComponent("usr/lib/tool"))
        let manager = SDKManager(layout: home.layout)
        do {
            _ = try await importing(manager, .inbox(path: "Bad.sdk"), home: home)
            XCTFail("imported an SDK with an executable")
        } catch {
            XCTAssertEqual((error as? ApelinError)?.code, .denied)
        }
        XCTAssertEqual(manager.list(SDKListRequest()).sdks, [])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: home.layout.sdks.path)) ?? [], [])
    }

    func testRemovalChecksProjectReferences() async throws {
        let home = try TemporaryHome(self)
        try SDKFixture.make(at: home.inbox.appendingPathComponent("iPhoneOS99.0.sdk"))
        let manager = SDKManager(layout: home.layout)
        let record = try await importing(manager, .inbox(path: "iPhoneOS99.0.sdk"), home: home)

        let project = home.layout.data.projects.appendingPathComponent("Hello")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let description = try #"{"projectID": "8a6f3c1e-0000-4000-8000-000000000001", "environment": {"toolchain": {"id": "t", "digest": "d"}, "sdk": {"id": "\#(record.id)", "digest": "\#(XCTUnwrap(record.digest))"}}}"#
        try Data(description.utf8).write(to: project.appendingPathComponent("apelin-project.json"))
        XCTAssertThrowsError(try manager.remove(SDKRemoveRequest(id: record.id))) { error in
            XCTAssertEqual((error as? ApelinError)?.code, .conflict)
            XCTAssertTrue(String(describing: error).contains("Hello"))
        }

        try FileManager.default.removeItem(at: project)
        _ = try manager.remove(SDKRemoveRequest(id: record.id))
        XCTAssertEqual(manager.list(SDKListRequest()).sdks, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
        XCTAssertThrowsError(try manager.remove(SDKRemoveRequest(id: record.id))) { XCTAssertEqual(($0 as? ApelinError)?.code, .notFound) }
    }

    func testAnUnrecordedTreeIsNotListedAndIsSwept() throws {
        let home = try TemporaryHome(self)
        let store = SDKStore(layout: home.layout)
        try SDKFixture.make(at: home.layout.sdks.appendingPathComponent("iphoneos99.0-deadbeef"))
        XCTAssertEqual(store.list(), [])
        store.sweepOrphans()
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.layout.sdks.appendingPathComponent("iphoneos99.0-deadbeef").path))
    }

    func testDefaultSourceIsEnabledAndAnExplicitListReplacesIt() throws {
        let home = try TemporaryHome(self)
        XCTAssertEqual(SDKSourceList.load(home.layout), .default)
        XCTAssertEqual(SDKSourceList.default.sources, SDKSourceList.knownSources)
        XCTAssertEqual(SDKSourceList.knownSources.map(\.enabled), [true])
        XCTAssertTrue(SDKSourceList.knownSources[0].url.contains("owngoal-dev/iOS-SDKs"))

        let configured = SDKSourceList(sources: [.init(name: "Mine", url: "https://example.invalid/sdks.git", enabled: false)])
        try home.layout.make(home.layout.environment)
        try JSONFile.write(configured, to: home.layout.sdkSources)
        let listed = SDKManager(layout: home.layout).list(SDKListRequest(includeSources: true, readSources: true)).sources
        // Disabled sources are listed and never read.
        XCTAssertEqual(listed, [SDKSourceStatus(name: "Mine", url: "https://example.invalid/sdks.git", enabled: false)])
        try JSONFile.write(SDKSourceList(), to: home.layout.sdkSources)
        XCTAssertFalse(SDKSourceList.load(home.layout).hasEnabledSource)
    }

    private func importing(_ manager: SDKManager, _ source: SDKSource, home: TemporaryHome) async throws -> SDKRecord {
        let prepared = try manager.prepare(SDKImportRequest(source: source), descriptors: [])
        let staging = try home.layout.makeStaging(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        let log = EventLog()
        let record = try await manager.run(prepared, staging: staging, hasSwiftToolchain: false, reporter: log.reporter)
        XCTAssertEqual(log.events.filter { $0.0 == "stage" }.compactMap { $0.1?["stage"]?.stringValue }.last, "registering")
        return record
    }
}

/// Answers every request to `sdk.example.invalid` with `body`, so an import
/// from a URL runs without a network.
private final class ArchiveURLStub: URLProtocol {
    static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sdk.example.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
