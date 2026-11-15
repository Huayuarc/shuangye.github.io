@testable import ApelinToolHost
import Darwin
import Foundation
import XCTest

final class ToolHostClientTests: XCTestCase {
    static var fakeExecutable: String {
        Bundle(for: ToolHostClientTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("FakeToolExtension").path
    }

    private func makeClient(limits: ToolProtocolLimits = ToolProtocolLimits(), environment: [String: String] = [:],
                            manifest: ToolManifest? = nil, log: LogCollector? = nil) -> ToolHostClient
    {
        var env = ToolHostClient.Configuration.defaultEnvironment()
        env.merge(environment) { _, new in new }
        let configuration = ToolHostClient.Configuration(executable: Self.fakeExecutable, environment: env, limits: limits,
                                                         manifest: manifest, logHandler: log.map { collector in { collector.append($0) } })
        return ToolHostClient(configuration: configuration)
    }

    func testGoodCall() async throws {
        let client = makeClient()
        let hello = try await client.start()
        XCTAssertEqual(hello.peer.name, "wiki.qaq.apelin.agent-tools.fake")
        XCTAssertEqual(hello.protocolVersion, ToolProtocol.version)
        XCTAssertTrue(hello.tools.contains("echo"))
        XCTAssertEqual(hello.maxConcurrentCalls, 2, "the extension lowers the host's limit")

        let outcome = await client.call(tool: "echo", arguments: ["text": "hello, tool"])
        XCTAssertEqual(outcome.result?.text, "hello, tool")
        let again = await client.call(tool: "echo", arguments: ["text": "second"])
        XCTAssertEqual(again.result?.text, "second")

        let exit = await client.terminate()
        XCTAssertEqual(exit, .exited(0), "closing stdin lets the extension exit cleanly")
    }

    func testToolFailureAndInvalidArgumentsLeaveTheExtensionRunning() async throws {
        let client = makeClient()
        try await client.start()
        let failed = await client.call(tool: "fail")
        XCTAssertEqual(failed.failure?.code, .toolFailed)
        XCTAssertEqual(failed.failure?.message, "deliberate failure")
        let invalid = await client.call(tool: "echo", arguments: ["wrong": 1])
        XCTAssertEqual(invalid.failure?.code, .invalidArguments)
        let unknown = await client.call(tool: "nonexistent")
        XCTAssertEqual(unknown.failure?.code, .unknownTool)
        XCTAssertTrue(client.isRunning)
        await client.terminate()
    }

    func testBadFrameStopsTheExtension() async throws {
        let client = makeClient()
        try await client.start()
        let outcome = await client.call(tool: "garbage")
        XCTAssertEqual(outcome.failure?.code, .badFrame)
        let exit = await client.waitForExit()
        XCTAssertEqual(exit, .signalled(SIGKILL))
        XCTAssertFalse(client.isRunning)
        let after = await client.call(tool: "echo", arguments: ["text": "x"])
        XCTAssertEqual(after.failure?.code, .extensionNotRunning)
    }

    func testOversizedFrameStopsTheExtension() async throws {
        let client = makeClient(limits: ToolProtocolLimits(maxFrameBytes: 64 * 1024))
        try await client.start()
        let outcome = await client.call(tool: "huge", arguments: ["bytes": 200_000])
        XCTAssertEqual(outcome.failure?.code, .frameTooLarge)
        _ = await client.waitForExit()
    }

    func testOversizedResultIsRefusedByTheExtension() async throws {
        let client = makeClient(limits: ToolProtocolLimits(maxFrameBytes: 64 * 1024))
        try await client.start()
        let outcome = await client.call(tool: "bigResult", arguments: ["bytes": 100_000])
        XCTAssertEqual(outcome.failure?.code, .resultTooLarge)
        let next = await client.call(tool: "echo", arguments: ["text": "still here"])
        XCTAssertEqual(next.result?.text, "still here")
        await client.terminate()
    }

    func testCrashMidCall() async throws {
        let log = LogCollector()
        let client = makeClient(log: log)
        try await client.start()
        let outcome = await client.call(tool: "crash")
        XCTAssertEqual(outcome.failure?.code, .extensionCrashed)
        XCTAssertTrue(outcome.failure?.message.contains("signal \(SIGABRT)") == true, outcome.failure?.message ?? "")
        XCTAssertTrue(outcome.failure?.message.contains("about to crash") == true, "the crash carries the stderr tail")
        let exit = await client.waitForExit()
        XCTAssertEqual(exit, .signalled(SIGABRT))
        XCTAssertTrue(log.lines.contains("about to crash"))
    }

    func testTimeoutCancelsAndKeepsTheExtension() async throws {
        let client = makeClient()
        try await client.start()
        let started = Date()
        let outcome = await client.call(tool: "sleep", arguments: ["seconds": 10], timeout: 0.3)
        XCTAssertEqual(outcome.failure?.code, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let next = await client.call(tool: "echo", arguments: ["text": "after timeout"])
        XCTAssertEqual(next.result?.text, "after timeout")
        XCTAssertTrue(client.isRunning)
        await client.terminate()
    }

    func testTimeoutOnAToolIgnoringCancelStopsTheExtension() async throws {
        let client = makeClient(limits: ToolProtocolLimits(cancelGrace: 0.5))
        try await client.start()
        let outcome = await client.call(tool: "hang", timeout: 0.3)
        XCTAssertEqual(outcome.failure?.code, .timeout)
        let exit = await client.waitForExit()
        XCTAssertEqual(exit, .signalled(SIGKILL))
        let after = await client.call(tool: "echo", arguments: ["text": "x"])
        XCTAssertEqual(after.failure?.code, .extensionNotRunning)
        XCTAssertTrue(after.failure?.message.contains("did not end") == true, after.failure?.message ?? "")
    }

    /// A call that times out while its result's file is being claimed was
    /// still ended by the extension: its slot comes back, and the extension
    /// is not stopped for leaving the cancel unanswered.
    func testTimeoutWhileClaimingAResultFileKeepsTheExtension() async throws {
        let client = makeClient(limits: ToolProtocolLimits(cancelGrace: 0.8, attachmentWait: 0.5))
        try await client.start()
        let outcome = await client.call(tool: "missingFile", timeout: 0.2)
        XCTAssertEqual(outcome.failure?.code, .timeout)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(client.isRunning, "\(String(describing: client.exitStatus))")
        let next = await client.call(tool: "echo", arguments: ["text": "still here"])
        XCTAssertEqual(next.result?.text, "still here")
        await client.terminate()
    }

    func testCancelByTaskAndByRequestID() async throws {
        let client = makeClient()
        try await client.start()

        let task = Task { await client.call(tool: "sleep", arguments: ["seconds": 10]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.failure?.code, .cancelled)

        let explicit = Task { await client.call(tool: "sleep", arguments: ["seconds": 10], requestID: "sleepy") }
        try await Task.sleep(nanoseconds: 200_000_000)
        client.cancel(requestID: "sleepy")
        let explicitOutcome = await explicit.value
        XCTAssertEqual(explicitOutcome.failure?.code, .cancelled)

        // Both slots come back once the extension acknowledges the cancels.
        async let first = client.call(tool: "sleep", arguments: ["seconds": 0.1], timeout: 3)
        async let second = client.call(tool: "sleep", arguments: ["seconds": 0.1], timeout: 3)
        let results = await [first, second]
        XCTAssertTrue(results.allSatisfy { $0.result != nil }, "\(results.map { $0.failure as Any })")
        await client.terminate()
    }

    func testConcurrencyLimitQueuesCalls() async throws {
        let client = makeClient()
        try await client.start()
        let started = Date()
        async let a = client.call(tool: "sleep", arguments: ["seconds": 0.4])
        async let b = client.call(tool: "sleep", arguments: ["seconds": 0.4])
        async let c = client.call(tool: "sleep", arguments: ["seconds": 0.4])
        let outcomes = await [a, b, c]
        XCTAssertTrue(outcomes.allSatisfy { $0.result != nil })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.8, "the third call waited for a slot")
        await client.terminate()
    }

    func testVersionMismatchFailsStart() async throws {
        let client = makeClient(environment: ["FAKE_PROTOCOL_VERSIONS": "99"])
        do {
            try await client.start()
            XCTFail("start succeeded against an extension speaking only version 99")
        } catch let failure as ToolCallFailure {
            XCTAssertEqual(failure.code, .protocolVersionMismatch)
        }
        XCTAssertFalse(client.isRunning)
    }

    func testManifestIsTheAuthorityOnTools() async throws {
        let echo = ToolDescriptor(name: "echo", description: "Echo.", parameters: ["type": "object"], risk: .readOnly)
        let manifest = ToolManifest(id: "wiki.qaq.apelin.agent-tools.fake", name: "Fake", version: "1.0", license: "MIT",
                                    executable: "fake", tools: [echo])
        let client = makeClient(manifest: manifest)
        try await client.start()
        let hang = await client.call(tool: "hang")
        XCTAssertEqual(hang.failure?.code, .unknownTool, "a tool the manifest does not list is not callable")
        await client.terminate()

        var missing = manifest
        missing.tools.append(ToolDescriptor(name: "absent", description: "Absent.", parameters: ["type": "object"], risk: .readOnly))
        let refused = makeClient(manifest: missing)
        do {
            try await refused.start()
            XCTFail("started an extension missing a declared tool")
        } catch {}

        let impostor = makeClient(environment: ["FAKE_EXTENSION_ID": "someone.else"], manifest: manifest)
        do {
            try await impostor.start()
            XCTFail("started an extension reporting another id")
        } catch {}
    }

    func testAttachmentsTravelAsDescriptors() async throws {
        let client = makeClient()
        try await client.start()
        let path = NSTemporaryDirectory() + "apelin-tool-attachment-\(getpid())"
        FileManager.default.createFile(atPath: path, contents: Data("hello".utf8))
        defer { unlink(path) }
        let attachment = try ToolOutgoingAttachment(path: path, argument: "file", mimeType: "text/plain")

        let outcome = await client.call(tool: "inspect", attachments: [attachment])
        guard let result = outcome.result else { return XCTFail("\(String(describing: outcome.failure))") }
        XCTAssertTrue(result.text.hasPrefix("received 5 bytes"))
        guard case let .file(file)? = result.content.last else { return XCTFail("no file in the result") }
        XCTAssertEqual(file.mimeType, "application/octet-stream")
        XCTAssertEqual(try file.readAll(), Data("olleh".utf8))
        await client.terminate()
    }

    /// What the session host sends and receives: a read-only descriptor to
    /// an unlinked file. It arrives whole, stays read-only on the other side,
    /// and the tool's own file comes back the same way.
    func testAnUnlinkedReadOnlyCopyTravelsBothWays() async throws {
        let client = makeClient()
        try await client.start()
        let path = NSTemporaryDirectory() + "apelin-tool-copy-\(getpid())"
        FileManager.default.createFile(atPath: path, contents: Data("abc\u{0}def".utf8))
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        unlink(path)
        defer { close(descriptor) }
        let attachment = try ToolOutgoingAttachment(duplicating: descriptor, argument: "file", name: "copy")

        let outcome = await client.call(tool: "inspect", attachments: [attachment])
        guard let result = outcome.result else { return XCTFail("\(String(describing: outcome.failure))") }
        XCTAssertTrue(result.text.hasPrefix("received 7 bytes"))
        XCTAssertTrue(result.text.hasSuffix("read-only"), "the extension cannot write what the host sent")
        guard case let .file(file)? = result.content.last else { return XCTFail("no file in the result") }
        XCTAssertEqual(file.byteCount, 7)
        XCTAssertEqual(try file.readAll(), Data("fed\u{0}cba".utf8))
        XCTAssertEqual(fcntl(file.descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
        await client.terminate()
    }

    func testDirectoryAttachmentIsRefused() async throws {
        let client = makeClient()
        try await client.start()
        let directory = try ToolOutgoingAttachment(path: NSTemporaryDirectory(), argument: "file")
        let outcome = await client.call(tool: "inspect", attachments: [directory])
        XCTAssertEqual(outcome.failure?.code, .attachmentRejected)
        await client.terminate()
    }

    func testStrayStdoutGoesToTheLog() async throws {
        let log = LogCollector()
        let client = makeClient(log: log)
        try await client.start()
        let outcome = await client.call(tool: "print")
        XCTAssertEqual(outcome.result?.text, "printed")
        await client.terminate()
        XCTAssertTrue(log.lines.contains("stray stdout line"), "\(log.lines)")
    }

    func testTerminateFailsCallsInFlight() async throws {
        let client = makeClient()
        try await client.start()
        let call = Task { await client.call(tool: "sleep", arguments: ["seconds": 10]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        await client.terminate()
        let outcome = await call.value
        XCTAssertEqual(outcome.failure?.code, .extensionTerminated)
    }

    func testMissingExecutableFailsStart() async {
        let client = ToolHostClient(configuration: .init(executable: "/nonexistent/extension"))
        do {
            try await client.start()
            XCTFail("started a missing executable")
        } catch let failure as ToolCallFailure {
            XCTAssertEqual(failure.code, .extensionNotRunning)
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
