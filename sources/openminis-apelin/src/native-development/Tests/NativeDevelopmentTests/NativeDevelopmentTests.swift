import XCTest
import Foundation
import Darwin
@testable import MinisNativeDevelopment

final class NativeDevelopmentTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws {
        for root in roots { try FileManager.default.removeItem(at: root) }
        roots = []
    }
    private func project(_ id: String = "p") throws -> ProjectRegistration {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        try Data("{\"projectID\":\"\(id)\"}".utf8).write(to: url.appendingPathComponent("apelin-project.json"))
        return ProjectRegistration(id: id, root: url.resolvingSymlinksInPath().path)
    }
    private func call(_ p: ProjectRegistration, session: String = "s", tool: String = "createMarker") throws -> Call {
        Call(session: session, project: p.id, tool: tool, cwd: p.root,
             descriptionDigest: digest(try Data(contentsOf: URL(fileURLWithPath: p.root).appendingPathComponent("apelin-project.json"))))
    }
    private func executable() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["NATIVE_SERVICE_EXECUTABLE"], !path.isEmpty else {
            XCTFail("Run Scripts/test-macos.sh: NATIVE_SERVICE_EXECUTABLE is required, tests must not silently skip IPC")
            throw NativeError.denied("missing test service")
        }
        return URL(fileURLWithPath: path)
    }
    private func launch(_ projects: [ProjectRegistration], lifetime: TimeInterval = 30) throws -> (NativeConnection, DecisionSigner) {
        try NativeConnection.connect(executable: executable(), projects: projects, sessions: ["s", "other"], challengeLifetime: lifetime)
    }
    private func challenge(_ connection: NativeConnection, _ call: Call) throws -> Challenge {
        try XCTUnwrap(connection.prepare(call).challenge)
    }
    private func exists(_ p: ProjectRegistration) -> Bool {
        FileManager.default.fileExists(atPath: p.root + "/.native-development-marker")
    }
    func testRealProcessReadApproveReplay() throws {
        let p = try project()
        let (connection, signer) = try launch([p]); defer { connection.disconnect() }
        let read = try connection.prepare(Call(session: "s", project: p.id, operation: .hostEnvironment,
            cwd: p.root, descriptionDigest: try call(p).descriptionDigest))
        XCTAssertNotNil(read.environment?["os"])
        XCTAssertNil(read.challenge)
        let review = try challenge(connection, call(p))
        XCTAssertEqual(review.facts?.operation, .createMarker)
        XCTAssertEqual(review.facts?.requiresAsk, true)
        XCTAssertEqual(review.facts?.canonicalRoot, p.root)
        XCTAssertFalse(exists(p))
        let signed = try signer.sign(review, decision: .allowOnce)
        XCTAssertEqual(try connection.execute(signed).markerCreated, true)
        XCTAssertTrue(exists(p))
        try FileManager.default.removeItem(atPath: p.root + "/.native-development-marker")
        XCTAssertThrowsError(try connection.decide(signed))
        XCTAssertFalse(exists(p))
    }
    func testDenyCancelSessionClientDisconnectAndNewConnectionIsolation() throws {
        let p = try project()
        let (connection, signer) = try launch([p])
        let denied = try challenge(connection, call(p))
        XCTAssertThrowsError(try connection.decide(signer.sign(denied, decision: .deny)))
        XCTAssertThrowsError(try connection.decide(signer.sign(denied, decision: .allowOnce)))
        let cancelled = try challenge(connection, call(p))
        try connection.cancel(cancelled)
        XCTAssertThrowsError(try connection.decide(signer.sign(cancelled, decision: .allowOnce)))
        let session = try challenge(connection, call(p))
        try connection.cancelSession("s")
        XCTAssertThrowsError(try connection.decide(signer.sign(session, decision: .allowOnce)))
        XCTAssertThrowsError(try connection.prepare(call(p)))
        let pending = try challenge(connection, call(p, session: "other"))
        connection.disconnect()
        XCTAssertThrowsError(try connection.decide(signer.sign(pending, decision: .allowOnce)))
        let (fresh, freshSigner) = try launch([p]); defer { fresh.disconnect() }
        XCTAssertThrowsError(try fresh.decide(freshSigner.sign(pending, decision: .allowOnce)))
        XCTAssertFalse(exists(p))
    }
    func testUnregisteredAndUnknownArgumentsDeny() throws {
        let p = try project(), q = try project("q")
        let (connection, _) = try launch([p]); defer { connection.disconnect() }
        XCTAssertThrowsError(try connection.prepare(call(q)))
        XCTAssertThrowsError(try connection.prepare(call(p, session: "invented")))
        XCTAssertThrowsError(try connection.prepare(call(p, tool: "shell_execute")))
        let valid = try call(p)
        XCTAssertThrowsError(try connection.prepare(Call(session: valid.session, project: valid.project,
            tool: valid.tool, cwd: p.root + "/..", descriptionDigest: valid.descriptionDigest)))
        XCTAssertThrowsError(try connection.prepare(Call(session: valid.session, project: valid.project,
            tool: valid.tool, cwd: p.root, descriptionDigest: "untrusted")))
        XCTAssertFalse(exists(p))
    }
    func testSignedContextTamperingBurnsNonce() throws {
        let p = try project(), q = try project("q")
        let (connection, signer) = try launch([p, q]); defer { connection.disconnect() }
        for variant in 0..<6 {
            let original = try challenge(connection, call(p))
            let c = original.call
            let changed = Call(session: variant == 0 ? "other" : c.session,
                project: variant == 1 ? q.id : c.project, tool: variant == 2 ? "hostEnvironment" : c.tool,
                cwd: variant == 3 ? q.root : c.cwd, descriptionDigest: variant == 4 ? "changed" : c.descriptionDigest)
            let altered = Challenge(nonce: original.nonce, connection: variant == 5 ? randomBytes() : original.connection,
                call: changed, canonicalRoot: original.canonicalRoot, expiresAt: original.expiresAt, review: original.review)
            // Even a trusted signer cannot substitute a different context for a stored challenge.
            XCTAssertThrowsError(try connection.decide(signer.sign(altered, decision: .allowOnce)))
            XCTAssertThrowsError(try connection.decide(signer.sign(original, decision: .allowOnce)))
        }
        XCTAssertFalse(exists(p)); XCTAssertFalse(exists(q))
    }
    func testWrongMACAndCrossConnection() throws {
        let p = try project()
        let (a, signerA) = try launch([p]); defer { a.disconnect() }
        let (b, signerB) = try launch([p]); defer { b.disconnect() }
        let original = try challenge(a, call(p))
        XCTAssertThrowsError(try b.decide(signerA.sign(original, decision: .allowOnce)))
        XCTAssertThrowsError(try a.decide(signerB.sign(original, decision: .allowOnce)))
        XCTAssertThrowsError(try a.decide(signerA.sign(original, decision: .allowOnce)))
        XCTAssertFalse(exists(p))
    }
    func testDescriptionChangeBeforeExpiryDenied() throws {
        let p = try project()
        let (connection, signer) = try launch([p]); defer { connection.disconnect() }
        let changed = try challenge(connection, call(p))
        try Data("{\"projectID\":\"p\",\"changed\":true}".utf8).write(to: URL(fileURLWithPath: p.root + "/apelin-project.json"))
        let decision = try signer.sign(changed, decision: .allowOnce)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime, changed.expiresAt)
        XCTAssertThrowsError(try connection.execute(decision))
        XCTAssertFalse(exists(p))
        // A fresh challenge against the changed, valid description must still execute.
        let fresh = try challenge(connection, call(p))
        XCTAssertNotEqual(fresh.call.descriptionDigest, changed.call.descriptionDigest)
        XCTAssertEqual(try connection.execute(signer.sign(fresh, decision: .allowOnce)).markerCreated, true)
    }
    func testExpiredDecisionDenied() throws {
        let p = try project()
        let (connection, signer) = try launch([p], lifetime: 0.1); defer { connection.disconnect() }
        let expired = try challenge(connection, call(p))
        let decision = try signer.sign(expired, decision: .allowOnce)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime, expired.expiresAt)
        XCTAssertThrowsError(try connection.execute(decision))
        XCTAssertFalse(exists(p))
    }
    func testFailedRegistrationReleasesRootDescriptor() throws {
        let p = try project()
        var rootInfo = stat()
        XCTAssertEqual(lstat(p.root, &rootInfo), 0)
        func rootDescriptorCount() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { Int32($0) }.filter { descriptor in
                var info = stat()
                return fstat(descriptor, &info) == 0 && info.st_dev == rootInfo.st_dev && info.st_ino == rootInfo.st_ino
            }.count
        }
        let baseline = try rootDescriptorCount()
        // Prove the detector sees the root fd on successful initialization and release.
        do {
            let registered = try RegisteredProject(p)
            XCTAssertEqual(try rootDescriptorCount(), baseline + 1)
            withExtendedLifetime(registered) {}
        }
        XCTAssertEqual(try rootDescriptorCount(), baseline)
        // All stored properties have initialized before descriptionDigest throws:
        // Swift invokes deinit, which owns and closes the raw fd exactly once.
        for invalid in ["not JSON", "{\"projectID\":\"wrong-project\"}"] {
            try Data(invalid.utf8).write(to: URL(fileURLWithPath: p.root + "/apelin-project.json"))
            for _ in 0..<64 { XCTAssertThrowsError(try RegisteredProject(p)) }
            XCTAssertEqual(try rootDescriptorCount(), baseline)
        }
    }
    func testDescriptionSymlinkAndRootReplacementDenied() throws {
        let p = try project()
        let (connection, signer) = try launch([p]); defer { connection.disconnect() }
        let original = try challenge(connection, call(p))
        let description = p.root + "/apelin-project.json"
        try FileManager.default.removeItem(atPath: description)
        try FileManager.default.createSymbolicLink(atPath: description, withDestinationPath: "elsewhere")
        XCTAssertThrowsError(try connection.decide(signer.sign(original, decision: .allowOnce)))
        XCTAssertFalse(exists(p))
        let q = try project("q")
        let (other, otherSigner) = try launch([q]); defer { other.disconnect() }
        let pending = try challenge(other, call(q))
        let old = q.root + "-old"
        try FileManager.default.moveItem(atPath: q.root, toPath: old)
        defer { try? FileManager.default.removeItem(atPath: old) }
        try FileManager.default.createDirectory(atPath: q.root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try other.decide(otherSigner.sign(pending, decision: .allowOnce)))
    }
    func testConcurrentRedemptionOnlyOneExecutes() throws {
        let p = try project()
        let (connection, signer) = try launch([p]); defer { connection.disconnect() }
        let signed = try signer.sign(challenge(connection, call(p)), decision: .allowOnce)
        let lock = NSLock()
        var successes = 0
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            if (try? connection.decide(signed).markerCreated) == true {
                lock.lock(); successes += 1; lock.unlock()
            }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertTrue(exists(p))
        try FileManager.default.removeItem(atPath: p.root + "/.native-development-marker")
        XCTAssertThrowsError(try connection.execute(signed))
        XCTAssertFalse(exists(p))
    }
    func testCancelRacingDecisionIsLinearized() throws {
        let p = try project()
        let (connection, signer) = try launch([p]); defer { connection.disconnect() }
        let pending = try challenge(connection, call(p))
        let signed = try signer.sign(pending, decision: .allowOnce)
        let lock = NSLock()
        var success = false
        var cancellationError: Error?
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            if index == 0 {
                do { try connection.cancel(pending) }
                catch { lock.lock(); cancellationError = error; lock.unlock() }
            } else {
                let result = (try? connection.decide(signed).markerCreated) == true
                lock.lock(); success = result; lock.unlock()
            }
        }
        XCTAssertNil(cancellationError)
        XCTAssertEqual(exists(p), success)
        XCTAssertThrowsError(try connection.decide(signed))
    }
    func testUnknownRiskFlagsAndExtraArgumentsAreRejected() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let sender = try FramedSocket(fds[0]), receiver = try FramedSocket(fds[1])
        defer { sender.close(); receiver.close() }
        let bootstrap = Bootstrap(version: 1, connection: randomBytes(), transportKey: randomBytes(),
            decisionKey: randomBytes(), sessions: ["s"], projects: [], lifetime: 30)
        let channel = AuthenticatedChannel(socket: receiver, bootstrap: bootstrap, host: false)
        let body = PacketBody(domain: "host.v1", connection: bootstrap.connection, sequence: 0,
            payload: Data("{\"action\":\"prepare\",\"risk\":false}".utf8))
        try sender.send(Packet(body: body, tag: authenticate(body, key: bootstrap.transportKey)))
        XCTAssertThrowsError(try channel.receive(Request.self))
        let engine = try ServiceEngine(bootstrap)
        XCTAssertThrowsError(try engine.handle(Request(action: "cancelSession", nonce: randomBytes(), session: "s"), live: {}))
    }
    func testPacketReplayAndTamperRejected() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let sender = try FramedSocket(fds[0]), receiver = try FramedSocket(fds[1])
        defer { sender.close(); receiver.close() }
        let bootstrap = Bootstrap(version: 1, connection: randomBytes(), transportKey: randomBytes(),
            decisionKey: randomBytes(), sessions: ["s"], projects: [], lifetime: 30)
        let channel = AuthenticatedChannel(socket: receiver, bootstrap: bootstrap, host: false)
        let body = PacketBody(domain: "host.v1", connection: bootstrap.connection, sequence: 0,
                              payload: try canonical(Request(action: "cancelSession", session: "s")))
        let packet = Packet(body: body, tag: try authenticate(body, key: bootstrap.transportKey))
        try sender.send(packet)
        XCTAssertEqual(try channel.receive(Request.self).session, "s")
        try sender.send(packet)
        XCTAssertThrowsError(try channel.receive(Request.self))
        let tampered = Packet(body: PacketBody(domain: "host.v1", connection: bootstrap.connection,
            sequence: 1, payload: body.payload), tag: randomBytes())
        try sender.send(tampered)
        XCTAssertThrowsError(try channel.receive(Request.self))
    }
}
