import ApelinCore
@testable import ApelinProtocol
import Darwin
import Foundation
import XCTest

final class WorkerChannelTests: XCTestCase {
    func testAnErrorReplyKeepsItsReason() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        let worker = WorkerChannel(adopting: b)
        defer { host.close(); worker.close() }
        host.onRequest { request in
            let reasoned = request.request.requestID == "with-reason"
            let error = reasoned ? RunCodeApproval.presetRefusal : ApelinError(.denied, "no reason")
            return (.failure(request.request.requestID, error), [])
        }
        host.start()
        worker.start()

        var request = try WireRequest(ProjectCheckRequest(projectID: "p"))
        request.requestID = "with-reason"
        let (reasoned, _) = try await worker.call(request)
        XCTAssertEqual(reasoned.result.failureValue?.reason, .notAPreset)
        XCTAssertEqual(reasoned.result.failureValue?.code, .denied)
        request.requestID = "without"
        let (plain, _) = try await worker.call(request)
        XCTAssertNil(plain.result.failureValue?.reason)

        // A peer that predates the field, and one that names a reason this
        // build does not know, both still decode.
        let old = try JSONCoding.decode(ApelinError.self, from: Data(#"{"code":"denied","message":"m"}"#.utf8))
        XCTAssertEqual(old, ApelinError(.denied, "m"))
        let newer = try JSONCoding.decode(
            ApelinError.self,
            from: Data(#"{"code":"denied","message":"m","reason":"later"}"#.utf8),
        )
        XCTAssertEqual(newer.reason?.rawValue, "later")
        XCTAssertFalse(try String(decoding: JSONCoding.encode(old), as: UTF8.self).contains("reason"))
    }

    func testRequestReplyWithDescriptorsBothWays() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        let worker = WorkerChannel(adopting: b)
        defer { host.close(); worker.close() }

        worker.onRequest { request in
            // Read what the host passed, answer with a descriptor of our own.
            var byte: UInt8 = 0
            let fd = request.descriptors.first?.rawValue ?? -1
            lseek(fd, 0, SEEK_SET)
            _ = read(fd, &byte, 1)
            let pipeEnds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
            defer { pipeEnds.deallocate() }
            pipe(pipeEnds)
            var reply: UInt8 = byte + 1
            _ = write(pipeEnds[1], &reply, 1)
            close(pipeEnds[1])
            return (.success(request.request.requestID, ProjectCheckResponse(passed: request.taskID == TaskID("t1"))), [OwnedDescriptor(adopting: pipeEnds[0])])
        }
        host.start()
        worker.start()

        let path = NSTemporaryDirectory() + "apelin-channel-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: path, contents: Data([41]))
        defer { unlink(path) }
        let file = OwnedDescriptor(adopting: open(path, O_RDONLY))

        let request = try WireRequest(ProjectCheckRequest(projectID: "p"))
        let (reply, descriptors) = try await host.call(request, descriptors: [file], taskID: TaskID("t1"))
        let response = try JSONCoding.decode(ProjectCheckResponse.self, from: reply.result.get())
        XCTAssertTrue(response.passed)
        XCTAssertEqual(descriptors.count, 1)
        var byte: UInt8 = 0
        XCTAssertEqual(read(descriptors[0].rawValue, &byte, 1), 1)
        XCTAssertEqual(byte, 42)
    }

    func testUnhandledRequestIsUnimplementedAndEventsArrive() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        let worker = WorkerChannel(adopting: b)
        defer { host.close(); worker.close() }
        let received = expectation(description: "event")
        host.onEvent { frame in
            XCTAssertEqual(frame.header.name, "log")
            XCTAssertEqual(frame.header.taskID, TaskID("t"))
            XCTAssertEqual(try? JSONCoding.decode(JSONValue.self, from: frame.body), .string("hi"))
            received.fulfill()
        }
        host.start()
        worker.start()

        let (reply, _) = try await host.call(WireRequest(SDKListRequest()))
        guard case let .failure(error) = reply.result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.code, .unimplemented)

        try worker.sendEvent(taskID: TaskID("t"), kind: "log", payload: .string("hi"))
        await fulfillment(of: [received], timeout: 5)
    }

    func testClosedChannelFailsPendingCalls() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        host.start()
        close(b)
        do {
            _ = try await host.call(WireRequest(SDKListRequest()))
            XCTFail("expected unavailable")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}
