import ApelinCrashBlame
import ApelinCrashReport
@testable import ApelinCrashSymbols
import XCTest

/// The milestone 1 path end to end: a SpringBoard crash in a tweak Apelin
/// built, symbolicated from the dSYM the build kept (matched by image UUID,
/// read in place), then blamed with the owner the session host recorded.
final class ProjectSymbolicationTests: XCTestCase {
    private let tweakPath = "/var/jb/usr/lib/TweakInject/ApelinHello.dylib"

    private func crash() throws -> CrashReport {
        let url = Fixture.directory.appendingPathComponent("SpringBoard-2026-10-17-101500.ips")
        let report = try ReportDecoder.decode(Data(contentsOf: url), fileName: url.lastPathComponent)
        return try XCTUnwrap(report.crash)
    }

    private func plainOpen(_ path: String) throws -> FileHandle {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw CocoaError(.fileNoSuchFile) }
        return handle
    }

    func testProjectDSYMsIndexOnlyDWARFSlices() {
        let dsyms = ProjectDSYMs(directories: [Fixture.directory])
        XCTAssertEqual(dsyms.entries.map(\.uuid), [Fixture.uuid.uuidString])
        XCTAssertEqual(dsyms.url(forUUID: Fixture.uuid.uuidString.lowercased())?.lastPathComponent, "fixture.dylib")
        XCTAssertTrue(dsyms.url(forUUID: Fixture.uuid.uuidString)?.path.contains(".dSYM/") == true)
        XCTAssertNil(dsyms.url(forUUID: UUID().uuidString))
    }

    func testAnEmptyDirectoryAnswersNothing() {
        let dsyms = ProjectDSYMs(directories: [Fixture.temporaryDirectory(self)])
        XCTAssertTrue(dsyms.entries.isEmpty)
        XCTAssertNil(dsyms.url(forUUID: Fixture.uuid.uuidString))
    }

    func testTheTweakFramesGetNamesAndLinesFromTheProjectDSYM() async throws {
        let crash = try crash()
        XCTAssertEqual(crash.images[1].uuid, Fixture.uuid.uuidString)

        let symbolicator = Symbolicator(
            dsyms: ProjectDSYMs(directories: [Fixture.directory]),
            openImage: { [self] in try plainOpen($0) },
        )
        let symbolicated = await symbolicator.symbolicate(crash)
        let frames = try XCTUnwrap(symbolicated.threads.first?.frames)

        XCTAssertEqual(frames[0].symbol, "beta")
        XCTAssertEqual(frames[0].symbolSource, .dsym)
        XCTAssertEqual(frames[0].sourceLine, Fixture.betaLine)
        XCTAssertEqual(frames[0].sourceFile.map { ($0 as NSString).lastPathComponent }, "fixture.c")
        XCTAssertEqual(frames[1].symbol, "alpha")
        XCTAssertEqual(frames[1].sourceLine, Fixture.alphaLine)
        // A system frame keeps what the report said.
        XCTAssertEqual(frames[2].symbol, "UIApplicationMain")
        XCTAssertEqual(frames[2].symbolSource, .report)
    }

    func testAMismatchedUUIDIsNotSymbolicated() async throws {
        var crash = try crash()
        crash.images[1].uuid = UUID().uuidString
        let symbolicated = await Symbolicator(
            dsyms: ProjectDSYMs(directories: [Fixture.directory]),
            openImage: { [self] in try plainOpen($0) },
        ).symbolicate(crash)
        XCTAssertNil(symbolicated.threads.first?.frames.first?.symbol)
    }

    func testTheTweakIsBlamedWithItsRecordedOwner() throws {
        let crash = try crash()
        var owner = PackageOwner(identifier: "wiki.qaq.apelin.hello")
        owner.version = "0.0.1"
        let owners = StaticPackageOwners(
            ownerByPath: ["/usr/lib/TweakInject/ApelinHello.dylib": owner],
            installRoot: "/var/jb",
        )
        let suspects = Blame.suspects(in: crash, packages: owners)
        let first = try XCTUnwrap(suspects.first)
        XCTAssertEqual(first.id, tweakPath)
        XCTAssertEqual(first.reasons, [.onFaultingStack, .injectedTweak])
        XCTAssertEqual(first.owner?.identifier, "wiki.qaq.apelin.hello")
        XCTAssertEqual(suspects.count, 1, "SpringBoard and UIKitCore are Apple's")
    }

    func testOwnerSpellingsCoverRootlessRoothideAndPrivate() {
        XCTAssertEqual(
            PackageOwnerPaths.spellings(of: "/var/jb/usr/lib/X.dylib", installRoot: nil),
            ["/var/jb/usr/lib/X.dylib", "/usr/lib/X.dylib", "/private/var/jb/usr/lib/X.dylib"],
        )
        let root = "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
        XCTAssertTrue(
            PackageOwnerPaths.spellings(of: root + "/usr/lib/X.dylib", installRoot: root + "/")
                .contains("/usr/lib/X.dylib"),
        )
        XCTAssertTrue(
            PackageOwnerPaths.spellings(of: "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF/usr/lib/X.dylib", installRoot: root)
                .contains("/usr/lib/X.dylib"),
        )
    }
}
