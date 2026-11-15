// Ported from Xrash (XrashKit/Tests/XrashSymbolsTests/SymbolStoreTests.swift, owngoal-dev/Xrash at 9dcfb4d).
// Copyright (c) 2026 OwnGoal Studio. MIT License: see LICENSE beside this folder's sources.

@testable import ApelinCrashSymbols
import XCTest

final class DSYMStoreTests: XCTestCase {
    func testImportsADSYMBundle() throws {
        let store = DSYMStore(directory: Fixture.temporaryDirectory(self))
        XCTAssertEqual(store.records.count, 0)

        let imported = try store.importDSYM(at: Fixture.dsymBundle)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.id, Fixture.uuid.uuidString)
        XCTAssertEqual(imported.first?.arch, "arm64")
        XCTAssertEqual(imported.first?.binaryName, "fixture.dylib")
        XCTAssertGreaterThan(imported.first?.byteCount ?? 0, 0)

        let url = try XCTUnwrap(store.url(forUUID: Fixture.uuid.uuidString))
        XCTAssertEqual(try Data(contentsOf: url), try Fixture.data(of: Fixture.dsymBinary))
        // Matching is case-insensitive because reports and dwarfdump disagree.
        XCTAssertNotNil(store.url(forUUID: Fixture.uuid.uuidString.lowercased()))
    }

    func testImportsABareMachOAndAFolderOfThem() throws {
        let bare = DSYMStore(directory: Fixture.temporaryDirectory(self))
        XCTAssertEqual(try bare.importDSYM(at: Fixture.dsymBinary).count, 1)

        // The folder holds the dSYM and the stripped dylib it came from, which
        // share a UUID. The one with DWARF has to win whatever order they list in.
        let folder = DSYMStore(directory: Fixture.temporaryDirectory(self))
        XCTAssertEqual(try folder.importDSYM(at: Fixture.directory).count, 1)
        let stored = try XCTUnwrap(folder.url(forUUID: Fixture.uuid.uuidString))
        let slice = try XCTUnwrap(MachOSlice.slice(of: Data(contentsOf: stored), uuid: Fixture.uuid))
        XCTAssertNotNil(slice.section(segment: "__DWARF", name: "__debug_line"))
    }

    /// A release's unpacked `*_dSYMs.zip`, when there is one to hand:
    /// `XRASH_DSYM_DIR=<folder> swift test`.
    func testImportsAnUnpackedReleaseArchiveWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["XRASH_DSYM_DIR"] else { throw XCTSkip("opt-in") }
        let store = DSYMStore(directory: Fixture.temporaryDirectory(self))
        let imported = try store.importDSYM(at: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(imported.count, 1)
    }

    func testRefusesAPathWithNoSymbols() throws {
        let store = DSYMStore(directory: Fixture.temporaryDirectory(self))
        let empty = Fixture.temporaryDirectory(self)
        XCTAssertThrowsError(try store.importDSYM(at: empty)) {
            XCTAssertEqual($0 as? SymbolStoreFailure, .noDebugSymbols)
        }
        XCTAssertEqual(store.revision, 0)
    }

    func testRevisionAndRecordsSurviveARestart() throws {
        let directory = Fixture.temporaryDirectory(self)
        let store = DSYMStore(directory: directory)
        _ = try store.importDSYM(at: Fixture.dsymBundle)
        XCTAssertEqual(store.revision, 1)

        let reopened = DSYMStore(directory: directory)
        XCTAssertEqual(reopened.revision, 1)
        XCTAssertEqual(reopened.records.map(\.id), [Fixture.uuid.uuidString])

        try reopened.remove(uuid: Fixture.uuid.uuidString)
        XCTAssertEqual(reopened.revision, 2)
        XCTAssertNil(reopened.url(forUUID: Fixture.uuid.uuidString))
        XCTAssertEqual(DSYMStore(directory: directory).records.count, 0)
    }

    func testReimportingReplacesTheRecordRatherThanDoublingIt() throws {
        let store = DSYMStore(directory: Fixture.temporaryDirectory(self))
        _ = try store.importDSYM(at: Fixture.dsymBundle)
        _ = try store.importDSYM(at: Fixture.dsymBundle)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.revision, 2)
    }
}
