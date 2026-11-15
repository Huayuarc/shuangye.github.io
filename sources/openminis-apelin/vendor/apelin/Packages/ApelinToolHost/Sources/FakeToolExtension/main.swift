@_spi(Testing) import ApelinToolExtension
import Darwin
import Foundation

// An extension that does what the tests ask of it, including breaking the
// protocol. `FAKE_PROTOCOL_VERSIONS` (comma-separated) changes the versions it
// claims; `FAKE_EXTENSION_ID` the id it reports.

let environment = ProcessInfo.processInfo.environment
let versions = environment["FAKE_PROTOCOL_VERSIONS"].map { $0.split(separator: ",").compactMap { Int($0) } }
    ?? ToolProtocol.supportedVersions
let identity = environment["FAKE_EXTENSION_ID"] ?? "wiki.qaq.apelin.agent-tools.fake"

let object: (_ properties: [String: JSONValue], _ required: [String]) -> JSONValue = { properties, required in
    ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
     "additionalProperties": false]
}

var server: ToolExtensionServer!

let tools: [ToolHandler] = [
    ToolHandler(ToolDescriptor(
        name: "echo",
        description: "Returns its text.",
        parameters: object(["text": ["type": "string"]], ["text"]),
        risk: .readOnly,
    )) { call in
        .text(call.arguments["text"]?.stringValue ?? "")
    },
    ToolHandler(ToolDescriptor(
        name: "sleep",
        description: "Sleeps, checking for cancellation.",
        parameters: object(["seconds": ["type": "number", "minimum": 0]], ["seconds"]),
        risk: .readOnly,
    )) { call in
        let seconds = call.arguments["seconds"]?.doubleValue ?? 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try call.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return .text("slept \(seconds)")
    },
    ToolHandler(ToolDescriptor(
        name: "hang",
        description: "Blocks its thread and ignores cancellation.",
        parameters: object([:], []),
        risk: .readOnly,
    )) { _ in
        sleep(600)
        return .text("woke")
    },
    ToolHandler(ToolDescriptor(
        name: "crash",
        description: "Aborts the process mid-call.",
        parameters: object([:], []),
        risk: .readOnly,
    )) { _ in
        FileHandle.standardError.write(Data("about to crash\n".utf8))
        abort()
    },
    ToolHandler(ToolDescriptor(
        name: "garbage",
        description: "Writes a line that is not a frame.",
        parameters: object([:], []),
        risk: .readOnly,
    )) { _ in
        server.writeRawForTesting(Data("this is not json\n".utf8))
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return .text("unreachable")
    },
    ToolHandler(ToolDescriptor(
        name: "huge",
        description: "Writes a line longer than any frame limit.",
        parameters: object(["bytes": ["type": "integer"]], ["bytes"]),
        risk: .readOnly,
    )) { call in
        let count = call.arguments["bytes"]?.intValue ?? 0
        server.writeRawForTesting(Data(repeating: UInt8(ascii: "x"), count: count) + Data([0x0A]))
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return .text("unreachable")
    },
    ToolHandler(ToolDescriptor(
        name: "bigResult",
        description: "Returns more text than a frame holds.",
        parameters: object(["bytes": ["type": "integer"]], ["bytes"]),
        risk: .readOnly,
    )) { call in
        .text(String(repeating: "y", count: call.arguments["bytes"]?.intValue ?? 0))
    },
    ToolHandler(ToolDescriptor(
        name: "print",
        description: "Prints to stdout, which must land in the log.",
        parameters: object([:], []),
        risk: .readOnly,
    )) { _ in
        print("stray stdout line")
        fflush(stdout)
        return .text("printed")
    },
    ToolHandler(ToolDescriptor(
        name: "inspect",
        description: "Reads the attachment passed for `file` and returns a copy as its own attachment.",
        parameters: object(["file": ["type": "string"]], []),
        risk: .readOnly,
    )) { call in
        guard let file = try call.attachment(forArgument: "file") else {
            throw ToolFailure.invalidArguments("no attachment for file")
        }
        let data = try file.readAll()
        let path = NSTemporaryDirectory() + "fake-tool-\(getpid())-\(call.requestID)"
        FileManager.default.createFile(atPath: path, contents: Data(data.reversed()))
        let copy = try ToolOutgoingAttachment(path: path, mimeType: "application/octet-stream", name: "reversed")
        unlink(path)
        var byte: UInt8 = 0
        let writable = pwrite(file.descriptor, &byte, 1, 0) >= 0 ? "writable" : "read-only"
        return ToolOutput([
            .text("received \(data.count) bytes, descriptor \(file.descriptor), \(writable)"),
            .file(copy),
        ])
    },
    ToolHandler(ToolDescriptor(
        name: "missingFile",
        description: "Ends the call with a result naming a file it never sends, then ignores the cancel for a while.",
        parameters: object([:], []),
        risk: .readOnly,
    )) { call in
        var frame = ToolFrame(type: .result, requestID: call.requestID)
        frame.content = [.attachment(ToolAttachmentReference(id: "never-sent"))]
        try server.writeRawForTesting(ToolFrameCodec.encode(frame))
        sleep(3)
        return .text("unreachable")
    },
    ToolHandler(ToolDescriptor(
        name: "fail",
        description: "Throws.",
        parameters: object([:], []),
        risk: .readOnly,
    )) { _ in
        throw ToolFailure("deliberate failure")
    },
]

server = ToolExtensionServer(
    peer: ToolPeer(name: identity, version: "1.0"),
    tools: tools,
    limits: ToolProtocolLimits(maxConcurrentCalls: 2),
    supportedVersions: versions,
)
server.run()
