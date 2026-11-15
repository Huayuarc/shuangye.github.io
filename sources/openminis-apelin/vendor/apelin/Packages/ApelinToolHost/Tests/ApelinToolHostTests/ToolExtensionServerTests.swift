@testable import ApelinToolCore
import Foundation
import XCTest

/// The extension's end, driven by hand over pipes: what it answers to a host
/// that breaks the protocol.
final class ToolExtensionServerTests: XCTestCase {
    private final class Session {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let reader: LineReader

        init() throws {
            process.executableURL = URL(fileURLWithPath: ToolHostClientTests.fakeExecutable)
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            reader = LineReader(descriptor: output.fileHandleForReading.fileDescriptor, maxLineBytes: 1 << 20)
        }

        func send(_ text: String) {
            input.fileHandleForWriting.write(Data((text + "\n").utf8))
        }

        func receive() throws -> ToolFrame {
            guard case let .line(line) = reader.next() else { throw CocoaError(.fileReadUnknown) }
            return try ToolFrameCodec.decode(line)
        }

        func hello() throws -> ToolFrame {
            send(#"{"protocolVersion":1,"type":"hello","requestID":"h","supportedVersions":[1]}"#)
            return try receive()
        }

        func close() {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }

    func testBadFrameIsAnsweredAndTheServerCarriesOn() throws {
        let session = try Session()
        defer { session.close() }
        XCTAssertEqual(try session.hello().type, .hello)

        session.send("not json at all")
        let error = try session.receive()
        XCTAssertEqual(error.type, .error)
        XCTAssertEqual(error.error?.code, .badFrame)
        XCTAssertNil(error.requestID)

        session.send(#"{"protocolVersion":1,"type":"nonsense","requestID":"r7"}"#)
        let salvaged = try session.receive()
        XCTAssertEqual(salvaged.error?.code, .badFrame)
        XCTAssertEqual(salvaged.requestID, "r7", "a JSON line that is not a frame still names its request")

        session.send(#"{"protocolVersion":1,"type":"call","requestID":"c1","tool":"echo","args":{"text":"ok"}}"#)
        let result = try session.receive()
        XCTAssertEqual(result.type, .result)
        XCTAssertEqual(result.content, [.text("ok")])
    }

    func testCallBeforeHelloAndWrongVersion() throws {
        let session = try Session()
        defer { session.close() }
        session.send(#"{"protocolVersion":1,"type":"call","requestID":"c1","tool":"echo","args":{"text":"ok"}}"#)
        XCTAssertEqual(try session.receive().error?.code, .notNegotiated)

        XCTAssertEqual(try session.hello().type, .hello)
        session.send(#"{"protocolVersion":2,"type":"call","requestID":"c2","tool":"echo","args":{"text":"ok"}}"#)
        let mismatch = try session.receive()
        XCTAssertEqual(mismatch.error?.code, .protocolVersionMismatch)
        XCTAssertEqual(mismatch.requestID, "c2")
    }

    func testHelloWithNoCommonVersion() throws {
        let session = try Session()
        defer { session.close() }
        session.send(#"{"protocolVersion":7,"type":"hello","requestID":"h","supportedVersions":[7,8]}"#)
        let reply = try session.receive()
        XCTAssertEqual(reply.type, .error)
        XCTAssertEqual(reply.error?.code, .protocolVersionMismatch)
    }

    func testOversizedLineIsAnsweredAndSkipped() throws {
        let session = try Session()
        defer { session.close() }
        XCTAssertEqual(try session.hello().type, .hello)
        session.send(String(repeating: "z", count: (1 << 20) + 10))
        XCTAssertEqual(try session.receive().error?.code, .frameTooLarge)
        session.send(#"{"protocolVersion":1,"type":"call","requestID":"c3","tool":"echo","args":{"text":"resynced"}}"#)
        XCTAssertEqual(try session.receive().content, [.text("resynced")])
    }

    func testBusyPastTheExtensionsLimit() throws {
        let session = try Session()
        defer { session.close() }
        XCTAssertEqual(try session.hello().maxConcurrentCalls, 2)
        for id in ["s1", "s2", "s3"] {
            session.send(#"{"protocolVersion":1,"type":"call","requestID":"\#(id)","tool":"sleep","args":{"seconds":0.3}}"#)
        }
        let first = try session.receive()
        XCTAssertEqual(first.requestID, "s3")
        XCTAssertEqual(first.error?.code, .busy)
        session.send(#"{"protocolVersion":1,"type":"cancel","requestID":"s1"}"#)
        let cancelled = try session.receive()
        XCTAssertEqual(cancelled.requestID, "s1")
        XCTAssertEqual(cancelled.error?.code, .cancelled)
        XCTAssertEqual(try session.receive().requestID, "s2")
    }

    /// A call whose result is still being written has ended: the host sends
    /// its next call the moment it reads that result, so the slot is free.
    func testACallBeingAnsweredHoldsNoSlot() throws {
        let session = try Session()
        defer { session.close() }
        XCTAssertEqual(try session.hello().maxConcurrentCalls, 2)
        // Nothing reads stdout yet, so this result's write blocks on the pipe.
        session.send(#"{"protocolVersion":1,"type":"call","requestID":"big","tool":"bigResult","args":{"bytes":600000}}"#)
        session.send(#"{"protocolVersion":1,"type":"call","requestID":"s1","tool":"sleep","args":{"seconds":1}}"#)
        Thread.sleep(forTimeInterval: 0.3)
        session.send(#"{"protocolVersion":1,"type":"call","requestID":"e1","tool":"echo","args":{"text":"ok"}}"#)
        var frames: [String: ToolFrame] = [:]
        while frames["e1"] == nil {
            let frame = try session.receive()
            frames[frame.requestID ?? ""] = frame
        }
        XCTAssertEqual(frames["big"]?.type, .result)
        XCTAssertEqual(frames["e1"]?.content, [.text("ok")], "\(String(describing: frames["e1"]?.error))")
    }

    func testDescribePrintsTheDescriptors() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ToolHostClientTests.fakeExecutable)
        process.arguments = ["--describe"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let description = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(description["id"], "wiki.qaq.apelin.agent-tools.fake")
        XCTAssertTrue(description["tools"]?.arrayValue?.contains { $0["name"] == "echo" } == true)
    }
}

final class LineReaderTests: XCTestCase {
    func testSplitsAndBoundsLines() {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]) }
        let payload = "one\r\n\ntwo\n" + String(repeating: "x", count: 50) + "\nthree"
        _ = payload.withCString { write(fds[1], $0, strlen($0)) }
        close(fds[1])
        let reader = LineReader(descriptor: fds[0], maxLineBytes: 10)
        XCTAssertEqual(reader.next(), .line(Data("one".utf8)))
        XCTAssertEqual(reader.next(), .line(Data("two".utf8)))
        XCTAssertEqual(reader.next(), .oversized)
        XCTAssertEqual(reader.next(), .line(Data("three".utf8)))
        XCTAssertEqual(reader.next(), .endOfFile)
    }
}

final class ToolAttachmentChannelTests: XCTestCase {
    /// A receive loop that ended on its own leaves its descriptors to
    /// `stop()`, so a number the process reused in between gets no wake byte.
    func testStopAfterTheLoopEndedWritesToNoReusedDescriptor() throws {
        let (mine, theirs) = try ToolAttachmentChannel.makePair()
        defer { close(theirs) }
        let channel = ToolAttachmentChannel(socket: mine, maxAttachmentBytes: 1024, maxPending: 4)
        channel.start()
        // A zero-length datagram ends the loop.
        XCTAssertEqual(send(theirs, nil, 0, 0), 0)
        Thread.sleep(forTimeInterval: 0.2)
        var reused: [Int32] = []
        for _ in 0 ..< 16 {
            var fds: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
            reused += fds
        }
        defer { reused.forEach { close($0) } }
        channel.stop()
        var polls = reused.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        XCTAssertEqual(poll(&polls, nfds_t(polls.count), 100), 0, "stop() wrote into a descriptor it no longer owned")
    }
}

final class ToolSchemaValidatorTests: XCTestCase {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "binary": ["type": "string", "minLength": 1],
            "count": ["type": "integer", "minimum": 1, "maximum": 10],
            "arch": ["type": "string", "enum": ["arm64", "x86_64"]],
        ],
        "required": ["binary"],
        "additionalProperties": false,
    ]

    func testAcceptsAndRejects() {
        XCTAssertNil(ToolSchemaValidator.problem(with: ["binary": "/bin/ls", "count": 3], against: schema))
        XCTAssertEqual(ToolSchemaValidator.problem(with: ["count": 3], against: schema), "args.binary is required")
        XCTAssertEqual(ToolSchemaValidator.problem(with: ["binary": "a", "count": 1.5], against: schema), "args.count must be integer")
        XCTAssertEqual(ToolSchemaValidator.problem(with: ["binary": "a", "count": 11], against: schema), "args.count must be at most 10")
        XCTAssertEqual(ToolSchemaValidator.problem(with: ["binary": "a", "other": 1], against: schema), "args.other is not a parameter")
        XCTAssertNotNil(ToolSchemaValidator.problem(with: ["binary": "a", "arch": "mips"], against: schema))
        XCTAssertNotNil(ToolSchemaValidator.problem(with: "not an object", against: schema))
    }

    /// 2^63 is whole but past Int's range: no Int, and no trap.
    func testWholeNumbersPastIntRangeDoNotTrap() {
        XCTAssertNil(JSONValue.number(0x1p63).intValue)
        XCTAssertEqual(JSONValue.number(-0x1p63).intValue, Int.min)
        XCTAssertEqual(
            ToolSchemaValidator.problem(with: .number(0x1p64), against: ["type": "integer", "maximum": .number(0x1p63)]),
            "args must be at most 9.223372036854776e+18",
        )
    }
}
