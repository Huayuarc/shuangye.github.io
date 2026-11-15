// Ported from Xrash (XrashKit/Tests/XrashSymbolsTests/SymbolicatorTests.swift, owngoal-dev/Xrash at 9dcfb4d).
// Copyright (c) 2026 OwnGoal Studio. MIT License: see LICENSE beside this folder's sources.

import ApelinCrashReport
@testable import ApelinCrashSymbols
import XCTest

final class SymbolicatorTests: XCTestCase {
    /// One thread, one frame inside `beta`, and an image that is the fixture.
    private func report(uuid: UUID = Fixture.uuid, base: UInt64 = 0x1_0000_0000) -> CrashReport {
        var crash = CrashReport()
        crash.device.osBuild = "99A99"
        crash.images = [BinaryImage(
            name: "fixture.dylib",
            path: Fixture.dylib.path,
            uuid: uuid.uuidString,
            base: base,
            size: 0x4000,
        )]
        var thread = ReportThread(index: 0)
        thread.frames = [Frame(
            imageIndex: 0,
            imageOffset: Fixture.insideBeta,
            address: base + Fixture.insideBeta,
        )]
        crash.threads = [thread]
        crash.lastExceptionBacktrace = [Frame(
            imageIndex: 0,
            imageOffset: Fixture.insideAlpha,
            address: base + Fixture.insideAlpha,
        )]
        return crash
    }

    private func symbolicator(
        dsyms: (any DSYMLookup)? = nil,
    ) -> Symbolicator {
        Symbolicator(
            dsyms: dsyms ?? DSYMStore(directory: Fixture.temporaryDirectory(self)),
            openImage: { path in
                guard let handle = FileHandle(forReadingAtPath: path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return handle
            },
        )
    }

    func testADSYMGivesNamesFilesAndLines() async throws {
        let dsyms = DSYMStore(directory: Fixture.temporaryDirectory(self))
        _ = try dsyms.importDSYM(at: Fixture.dsymBundle)

        let seen = Fixture.Recorder<SymbolicationProgress>()
        let symbolicated = await symbolicator(dsyms: dsyms)
            .symbolicate(report()) { seen.record($0) }

        let frame = try XCTUnwrap(symbolicated.threads.first?.frames.first)
        XCTAssertEqual(frame.symbol, "beta")
        XCTAssertEqual(frame.symbolSource, .dsym)
        XCTAssertEqual(frame.symbolLocation, Fixture.insideBeta - Fixture.betaStart)
        XCTAssertEqual(frame.sourceLine, Fixture.betaLine)
        XCTAssertTrue(frame.sourceFile?.hasSuffix("fixture.c") == true, frame.sourceFile ?? "nil")
        XCTAssertFalse(frame.isInlined)

        // The last exception backtrace is symbolicated the same way.
        XCTAssertEqual(symbolicated.lastExceptionBacktrace.first?.symbol, "alpha")
        XCTAssertEqual(symbolicated.lastExceptionBacktrace.first?.sourceLine, Fixture.alphaLine)

        XCTAssertEqual(seen.values.last?.completedImages, 1)
        XCTAssertEqual(seen.values.last?.totalImages, 1)
    }

    func testTheBinaryOnDiskGivesNamesButNoLines() async throws {
        let symbolicated = await symbolicator().symbolicate(report())
        let frame = try XCTUnwrap(symbolicated.threads.first?.frames.first)
        XCTAssertEqual(frame.symbol, "beta")
        XCTAssertEqual(frame.symbolSource, .binary)
        XCTAssertEqual(frame.symbolLocation, Fixture.insideBeta - Fixture.betaStart)
        XCTAssertNil(frame.sourceFile)
        XCTAssertNil(frame.sourceLine)
    }

    func testADSYMBeatsTheBinary() async throws {
        let dsyms = DSYMStore(directory: Fixture.temporaryDirectory(self))
        let symbolicator = symbolicator(dsyms: dsyms)
        // Before the import the binary is all there is, and the cache that
        // answer lands in must not outlive the import.
        let binary = await symbolicator.symbolicate(report())
        XCTAssertEqual(binary.threads.first?.frames.first?.symbolSource, .binary)

        _ = try dsyms.importDSYM(at: Fixture.dsymBundle)
        let symbolicated = await symbolicator.symbolicate(report())
        XCTAssertEqual(symbolicated.threads.first?.frames.first?.symbolSource, .dsym)
    }

    func testABinaryThatNoLongerMatchesIsLeftAlone() async throws {
        // The image was rebuilt since the crash: its addresses now name other
        // functions, so a name from it would be a confident wrong answer.
        let symbolicated = await symbolicator().symbolicate(report(uuid: UUID()))
        let frame = try XCTUnwrap(symbolicated.threads.first?.frames.first)
        XCTAssertNil(frame.symbol)
        XCTAssertNil(frame.symbolSource)
        XCTAssertNil(frame.sourceLine)
    }

    func testApplesOwnNameIsKeptWhenNothingBetterIsFound() async throws {
        var crash = report(uuid: UUID())
        crash.threads[0].frames[0].symbol = "beta"
        let symbolicated = await symbolicator().symbolicate(crash)
        let frame = try XCTUnwrap(symbolicated.threads.first?.frames.first)
        XCTAssertEqual(frame.symbol, "beta")
        XCTAssertEqual(frame.symbolSource, .report)
    }

    func testAFrameWithNoImageIsLeftAlone() async {
        var crash = report()
        crash.threads[0].frames = [Frame(imageIndex: nil, imageOffset: 0, address: 0xDEAD)]
        let symbolicated = await symbolicator().symbolicate(crash)
        XCTAssertNil(symbolicated.threads.first?.frames.first?.symbol)
    }

    func testSymbolicatingTwiceGivesTheSameReport() async throws {
        let dsyms = DSYMStore(directory: Fixture.temporaryDirectory(self))
        _ = try dsyms.importDSYM(at: Fixture.dsymBundle)
        let symbolicator = symbolicator(dsyms: dsyms)
        let once = await symbolicator.symbolicate(report())
        let twice = await symbolicator.symbolicate(once)
        XCTAssertEqual(once, twice)
    }
}
