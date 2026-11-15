import ApelinDiagnosticsCore
@testable import ConfirmLoaded
import XCTest

final class InjectionFilterTests: XCTestCase {
    private func filter(_ text: String) throws -> InjectionFilter {
        try InjectionFilter(data: Data(text.utf8))
    }

    private let springBoard = FilterTarget(bundleIdentifier: "com.apple.springboard", executableName: "SpringBoard")

    func testApelinHelloSelectsSpringBoard() throws {
        // The research tweak's plist, verbatim.
        let hello = try filter(#"{ Filter = { Bundles = ( "com.apple.springboard" ); }; }"#)
        XCTAssertEqual(hello.bundles, ["com.apple.springboard"])
        XCTAssertEqual(hello.evaluate(for: springBoard).verdict, .matches)
        let settings = FilterTarget(bundleIdentifier: "com.apple.Preferences", executableName: "Preferences")
        XCTAssertEqual(hello.evaluate(for: settings).verdict, .doesNotMatch)
    }

    func testAFrameworkBundleIsUndetermined() throws {
        let uikit = try filter(#"{ Filter = { Bundles = ( "com.apple.UIKit" ); }; }"#)
        XCTAssertEqual(uikit.evaluate(for: springBoard).verdict, .undetermined)
    }

    func testExecutablesAndModes() throws {
        let both = try filter(#"{ Filter = { Bundles = ( "com.apple.springboard" ); Executables = ( "backboardd" ); }; }"#)
        XCTAssertEqual(both.evaluate(for: springBoard).verdict, .doesNotMatch, "every key must match")
        let any = try filter(#"{ Filter = { Mode = Any; Bundles = ( "com.apple.springboard" ); Executables = ( "backboardd" ); }; }"#)
        XCTAssertEqual(any.evaluate(for: springBoard).verdict, .matches)
        let backboardd = FilterTarget(bundleIdentifier: nil, executableName: "backboardd")
        XCTAssertEqual(any.evaluate(for: backboardd).verdict, .matches)
    }

    func testClassesAreOnlyKnowableInside() throws {
        let classes = try filter(#"{ Filter = { Classes = ( "SBIconController" ); }; }"#)
        XCTAssertEqual(classes.evaluate(for: springBoard).verdict, .undetermined)
        let anyWithHit = try filter(#"{ Filter = { Mode = Any; Classes = ( "X" ); Executables = ( "SpringBoard" ); }; }"#)
        XCTAssertEqual(anyWithHit.evaluate(for: springBoard).verdict, .matches)
    }

    func testCoreFoundationVersionRange() throws {
        let ranged = try filter(#"{ Filter = { Bundles = ( "com.apple.springboard" ); CoreFoundationVersion = ( 1900, 2000 ); }; }"#)
        var target = springBoard
        XCTAssertEqual(ranged.evaluate(for: target).verdict, .undetermined, "version not known")
        target.coreFoundationVersion = 1953.1
        XCTAssertEqual(ranged.evaluate(for: target).verdict, .matches)
        target.coreFoundationVersion = 2000
        XCTAssertEqual(ranged.evaluate(for: target).verdict, .doesNotMatch, "max is exclusive")
    }

    func testNoFilterAndEmptyFilter() throws {
        XCTAssertEqual(try filter("{ }").evaluate(for: springBoard).verdict, .matches)
        XCTAssertFalse(try filter("{ }").hasFilter)
        XCTAssertEqual(try filter("{ Filter = { }; }").evaluate(for: springBoard).verdict, .matches)
        XCTAssertEqual(try filter("{ Filter = { Mode = Any; }; }").evaluate(for: springBoard).verdict, .doesNotMatch)
    }

    func testXMLPlistsParseToo() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Filter</key><dict><key>Executables</key>
        <array><string>SpringBoard</string></array></dict></dict></plist>
        """
        XCTAssertEqual(try filter(xml).evaluate(for: springBoard).verdict, .matches)
    }

    func testNonsenseIsRefused() {
        XCTAssertThrowsError(try filter("not a plist {{{"))
        XCTAssertThrowsError(try filter("( a, b )"))
        XCTAssertThrowsError(try filter("{ Filter = ( a ); }"))
        XCTAssertThrowsError(try InjectionFilter(data: Data(count: InjectionFilter.maximumBytes + 1)))
    }
}

private struct FakeLogs: LogEvidenceSource {
    var entries: [LogEntry]
    var error: DiagnosticsError?

    func readLogs(_: LogFilter) throws -> LogReadResult {
        if let error {
            throw error
        }
        return LogReadResult(entries: entries, truncated: false, source: .icli)
    }
}

final class ConfirmLoadedTests: XCTestCase {
    private func request(window: TimeInterval = 1) -> LoadConfirmationRequest {
        LoadConfirmationRequest(
            marker: "ApelinHello: loaded into",
            targetExecutable: "SpringBoard",
            targetBundleIdentifier: "com.apple.springboard",
            dylibPath: "/var/jb/Library/MobileSubstrate/DynamicLibraries/ApelinHello.dylib",
            filterPlist: Data(#"{ Filter = { Bundles = ( "com.apple.springboard" ); }; }"#.utf8),
            logWindow: window,
        )
    }

    private func line(_ process: String, _ pid: Int32, _ message: String) -> LogEntry {
        LogEntry(date: Date(), process: process, pid: pid, subsystem: "", category: "", level: .default, message: message)
    }

    func testTheMarkerAndFilterConfirmAfterTheTrigger() {
        let triggered = Flag()
        let stages = Stages()
        let confirm = ConfirmLoaded(logs: FakeLogs(entries: [
            line("SpringBoardHelper", 801, "ApelinHello: loaded into SpringBoardHelper"),
            line("SpringBoard", 1200, "ApelinHello: loaded into SpringBoard"),
        ]))
        let result = confirm.run(request(), trigger: { triggered.set() }, stage: stages.append)
        XCTAssertTrue(triggered.value)
        XCTAssertEqual(stages.values, [.listening, .trigger])
        XCTAssertEqual(result.marker.status, .confirmed)
        XCTAssertEqual(result.marker.detail, "Marker logged by pid 1200.", "another process's marker does not count")
        XCTAssertEqual(result.filter.status, .confirmed)
        XCTAssertNil(result.triggerFailure)
        XCTAssertTrue(result.isLoaded, "the marker is the evidence")
    }

    func testTheImageListIsNeverRead() {
        let confirm = ConfirmLoaded(logs: FakeLogs(entries: [line("SpringBoard", 1200, "ApelinHello: loaded into SpringBoard")]))
        let result = confirm.run(request())
        XCTAssertEqual(result.image.status, .notRead)
        // An agent on iOS 17 took "the iOS 27 kernel" for a rule about
        // another system.
        XCTAssertTrue(result.image.detail.contains("on any iOS version"), result.image.detail)
        XCTAssertNil(result.image.detail.range(of: #"iOS \d"#, options: .regularExpression), result.image.detail)
    }

    func testEachEvidenceFailsOnItsOwn() {
        struct RespringFailed: Error {}
        let confirm = ConfirmLoaded(logs: FakeLogs(entries: [line("SpringBoard", 1200, "something else")]))
        var request = request()
        request.targetBundleIdentifier = "com.apple.Preferences"
        let result = confirm.run(request) { throw RespringFailed() }
        XCTAssertEqual(result.marker.status, .absent)
        XCTAssertEqual(result.filter.status, .absent)
        XCTAssertNotNil(result.triggerFailure)
        XCTAssertFalse(result.isLoaded)
    }

    func testMissingSourcesAreUnavailableNotAbsent() {
        var request = request()
        request.filterPlist = nil
        let result = ConfirmLoaded(logs: FakeLogs(entries: [])).run(request)
        XCTAssertEqual(result.filter.status, .unavailable)

        let failingLogs = ConfirmLoaded(logs: FakeLogs(entries: [], error: .unavailable("no stream")))
        XCTAssertEqual(failingLogs.run(self.request()).marker.status, .unavailable)
    }
}

private final class Stages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ConfirmLoaded.Stage] = []
    func append(_ stage: ConfirmLoaded.Stage) {
        lock.lock(); stored.append(stage); lock.unlock()
    }

    var values: [ConfirmLoaded.Stage] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() {
        lock.lock(); stored = true; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}
