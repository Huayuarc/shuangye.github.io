// Ported from Xrash (XrashKit/Tests/XrashBlameTests/BlameTests.swift, owngoal-dev/Xrash at 9dcfb4d).
// Copyright (c) 2026 OwnGoal Studio. MIT License: see LICENSE beside this folder's sources.

@testable import ApelinCrashBlame
import ApelinCrashReport
import XCTest

/// One synthetic crash per rule. The scores themselves are asserted: they are
/// the order the user sees, so a change to one has to be a deliberate change.
final class BlameTests: XCTestCase {
    private let appExecutable = "/var/containers/Bundle/Application/00000000/Fila.app/Fila"
    private let tweak = "/var/jb/Library/MobileSubstrate/DynamicLibraries/Zebra.dylib"

    func testAppleAndOwnBundleImagesAreNeverSuspects() {
        let report = crash(
            images: [
                image("/usr/lib/libsystem_c.dylib"),
                image("/System/Library/Frameworks/UIKit.framework/UIKit", source: "S"),
                image("/var/containers/Bundle/Application/00000000/Fila.app/Frameworks/SnapKit.framework/SnapKit"),
            ],
            faultingFrames: [0, 1, 2],
        )
        XCTAssertEqual(Blame.suspects(in: report, packages: nil), [])
    }

    func testUnknownImagesAreNeverSuspects() {
        for path in ["", " \n\t"] {
            let unknown = image(path, source: "A")
            let quiet = crash(processPath: "/usr/libexec/backboardd", images: [unknown])
            XCTAssertEqual(Blame.suspects(in: quiet, packages: nil), [])

            let onStack = crash(
                images: [unknown, image(tweak)],
                faultingFrames: [0, 1],
                exceptionFrames: [0],
            )
            XCTAssertEqual(Blame.suspects(in: onStack, packages: nil).map(\.id), [tweak])
        }
    }

    func testImagesWithOnlyANameOrPathCanStillBeSuspects() {
        var nameOnly = image("")
        nameOnly.name = "Named.dylib"
        var pathOnly = image(tweak)
        pathOnly.name = ""
        let report = crash(images: [nameOnly, pathOnly], faultingFrames: [0, 1])
        XCTAssertEqual(Blame.suspects(in: report, packages: nil).map(\.id), [tweak, ""])
    }

    func testTweakAtTheTopOfTheFaultingStackScoresHighest() throws {
        let report = crash(images: [image(tweak)], faultingFrames: [0])
        let suspect = try XCTUnwrap(Blame.suspects(in: report, packages: nil).first)
        XCTAssertEqual(suspect.reasons, [.onFaultingStack, .injectedTweak])
        XCTAssertEqual(suspect.score, 70 + 30)
        XCTAssertEqual(suspect.id, tweak)
        XCTAssertEqual(suspect.imageName, "Zebra.dylib")
    }

    /// Past the eighth frame the tweak is more likely a passer-by.
    func testADeeperFrameScoresLess() {
        let unattributed = [Int?](repeating: nil, count: 10)
        let report = crash(images: [image(tweak)], faultingFrames: unattributed + [0])
        XCTAssertEqual(Blame.suspects(in: report, packages: nil).first?.score, 50 + 30)
    }

    func testTheExceptionBacktraceCounts() throws {
        let dylib = "/var/jb/usr/lib/libthing.dylib"
        let report = crash(images: [image(dylib)], exceptionFrames: [0])
        let suspect = try XCTUnwrap(Blame.suspects(in: report, packages: nil).first)
        XCTAssertEqual(suspect.reasons, [.inExceptionBacktrace, .thirdPartyImage])
        XCTAssertEqual(suspect.score, 40 + 10)
    }

    /// `/cores/systemhook.dylib` is in every process on the device, so its mere
    /// presence must never accuse it.
    func testABootstrapHookIsOnlyBlamedFromTheStack() {
        let hook = "/cores/systemhook.dylib"
        let quiet = crash(processPath: "/usr/libexec/backboardd", images: [image(hook)])
        XCTAssertEqual(Blame.suspects(in: quiet, packages: nil), [])

        let loud = crash(processPath: "/usr/libexec/backboardd", images: [image(hook)], faultingFrames: [0])
        XCTAssertEqual(Blame.suspects(in: loud, packages: nil).first?.id, hook)
    }

    /// A sideloaded app's own dylibs are not evidence that it crashed.
    func testAThirdPartyProcessIsNotBlamedForMerelyLoadingThirdPartyCode() {
        let dylib = "/var/jb/usr/lib/libbystander.dylib"
        let own = crash(processPath: appExecutable, images: [image(dylib)])
        XCTAssertEqual(Blame.suspects(in: own, packages: nil), [])

        let apples = crash(processPath: "/usr/libexec/backboardd", images: [image(dylib)])
        XCTAssertEqual(Blame.suspects(in: apples, packages: nil).first?.score, 10)
    }

    func testARecentlyInstalledPackageIsCalledOut() throws {
        let root = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF")
        let packages = owners(listing: "/usr/lib/libfresh.dylib", as: "com.example.fresh", root: root.path)

        let path = root.appendingPathComponent("usr/lib/libfresh.dylib").path
        let report = crash(
            processPath: "/usr/libexec/backboardd",
            images: [image(path)],
            captureDate: Date(),
        )
        let suspect = try XCTUnwrap(Blame.suspects(in: report, packages: packages).first)
        XCTAssertEqual(suspect.reasons, [.thirdPartyImage, .recentlyInstalled])
        XCTAssertEqual(suspect.score, 10 + 15)
        XCTAssertEqual(suspect.owner?.identifier, "com.example.fresh")
    }

    func testAnOldPackageIsNotCalledOut() throws {
        let root = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF")
        let packages = owners(listing: "/usr/lib/libold.dylib", as: "com.example.old", root: root.path)

        let path = root.appendingPathComponent("usr/lib/libold.dylib").path
        let report = crash(
            processPath: "/usr/libexec/backboardd",
            images: [image(path)],
            captureDate: Date().addingTimeInterval(100 * 60 * 60),
        )
        let suspect = try XCTUnwrap(Blame.suspects(in: report, packages: packages).first)
        XCTAssertEqual(suspect.reasons, [.thirdPartyImage])
    }

    func testSuspectsAreRankedByScoreThenName() {
        let report = crash(
            processPath: "/usr/libexec/backboardd",
            images: [
                image("/var/jb/usr/lib/libz-bystander.dylib"),
                image("/var/jb/usr/lib/liba-bystander.dylib"),
                image(tweak),
            ],
            faultingFrames: [2],
        )
        XCTAssertEqual(
            Blame.suspects(in: report, packages: nil).map(\.imageName),
            ["Zebra.dylib", "liba-bystander.dylib", "libz-bystander.dylib"],
        )
    }

    // MARK: Building reports

    private func image(_ path: String, source: String? = "P") -> BinaryImage {
        var image = BinaryImage(
            name: (path as NSString).lastPathComponent,
            path: path,
            uuid: "00000000-0000-0000-0000-000000000000",
            base: 0x10000,
            size: 0x4000,
        )
        image.source = source
        return image
    }

    /// `faultingFrames` and `exceptionFrames` are image indices in frame order;
    /// nil is a frame the report could not attribute to any image.
    private func crash(
        processPath: String? = nil,
        images: [BinaryImage],
        faultingFrames: [Int?] = [],
        exceptionFrames: [Int?] = [],
        captureDate: Date? = nil,
    ) -> CrashReport {
        var report = CrashReport()
        report.process.name = "Fila"
        report.process.path = processPath ?? appExecutable
        report.device.captureDate = captureDate
        report.images = images

        var thread = ReportThread(index: 0)
        thread.isTriggered = true
        thread.frames = faultingFrames.map(frame)
        report.threads = [thread]
        report.faultingThreadIndex = 0
        report.lastExceptionBacktrace = exceptionFrames.map(frame)
        return report
    }

    private func frame(_ imageIndex: Int?) -> Frame {
        Frame(imageIndex: imageIndex, imageOffset: 0x200, address: 0x10200)
    }

    /// What the session host's installation record would hand over: the
    /// package's file, installed just now, under a roothide root.
    private func owners(listing: String, as package: String, root: String) -> StaticPackageOwners {
        var owner = PackageOwner(identifier: package)
        owner.installed = Date()
        return StaticPackageOwners(ownerByPath: [listing: owner], installRoot: root)
    }
}
