import Foundation

/// The wire between the host and one extension process: one JSON object per
/// line, stdin carrying the host's frames and stdout the extension's. stderr
/// is the extension's log and never parsed.
///
/// Every frame carries `protocolVersion` and `requestID`. The host opens with
/// `hello`; the extension answers `hello` or `error`. After that the host
/// sends `call` and `cancel`, and the extension ends every call with exactly
/// one `result` or `error` carrying the call's `requestID`.
public enum ToolProtocol {
    /// The version this build speaks.
    public static let version = 1
    /// Every version this build can speak, newest last.
    public static let supportedVersions = [1]
    /// The descriptor the host passes the attachment socket on, also named in
    /// the environment as `APELIN_TOOL_ATTACHMENT_FD`.
    public static let attachmentDescriptor: Int32 = 3
    public static let attachmentEnvironmentKey = "APELIN_TOOL_ATTACHMENT_FD"
    public static let protocolEnvironmentKey = "APELIN_TOOL_PROTOCOL"
    /// A request ID is at most this many bytes of printable ASCII.
    public static let maxRequestIDBytes = 128
}

public enum ToolFrameType: String, Codable, Sendable {
    case hello
    case call
    case result
    case error
    case cancel
}

/// Who is on the other end, as each side introduces itself in `hello`.
public struct ToolPeer: Codable, Hashable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// A file travelling beside a frame. The descriptor itself goes over the
/// attachment socket with `id` as its only payload; the receiver maps `id` to
/// the descriptor it received. A descriptor number never appears in JSON.
public struct ToolAttachmentReference: Codable, Hashable, Sendable {
    public var id: String
    /// On a `call`: the argument the file stands in for, so a tool reading
    /// `binary` takes this descriptor instead of opening the path.
    public var argument: String?
    public var mimeType: String?
    public var name: String?
    public var byteCount: Int?

    public init(
        id: String,
        argument: String? = nil,
        mimeType: String? = nil,
        name: String? = nil,
        byteCount: Int? = nil,
    ) {
        self.id = id
        self.argument = argument
        self.mimeType = mimeType
        self.name = name
        self.byteCount = byteCount
    }
}

/// One block of a result: text, or a file sent as an attachment.
public enum ToolContent: Codable, Hashable, Sendable {
    case text(String)
    case attachment(ToolAttachmentReference)

    private enum CodingKeys: String, CodingKey { case type, text }
    private enum Kind: String, Codable { case text, attachment }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text: self = try .text(container.decode(String.self, forKey: .text))
        case .attachment: self = try .attachment(ToolAttachmentReference(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .attachment(reference):
            try container.encode(Kind.attachment, forKey: .type)
            try reference.encode(to: encoder)
        }
    }
}

/// Why a call, or the handshake, did not produce a result. The raw value is
/// what travels in an `error` frame's `code`.
public enum ToolErrorCode: String, Codable, Sendable {
    /// The extension speaks no version the host does.
    case protocolVersionMismatch
    /// A frame did not parse, named an unknown type, or broke the protocol.
    case badFrame
    /// A frame was longer than the limit.
    case frameTooLarge
    /// A call arrived before `hello`.
    case notNegotiated
    case unknownTool
    case invalidArguments
    /// More calls in flight than the receiver allows.
    case busy
    /// A `requestID` already in flight.
    case duplicateRequest
    /// The tool ran and failed.
    case toolFailed
    /// The result was larger than a frame may be.
    case resultTooLarge
    case attachmentRejected
    case cancelled
    case timeout
    /// The process exited or was killed while the call was in flight.
    case extensionCrashed
    /// The host stopped the process.
    case extensionTerminated
    /// The process is not running.
    case extensionNotRunning
    /// Anything a newer peer sends that this build has no name for.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ToolErrorCode(rawValue: raw) ?? .unknown
    }
}

public struct ToolErrorPayload: Codable, Hashable, Sendable {
    public var code: ToolErrorCode
    public var message: String

    public init(code: ToolErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// One line of the wire. Which optional fields are present depends on `type`;
/// unknown keys are ignored so a newer peer can add fields within a version.
public struct ToolFrame: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var type: ToolFrameType
    /// Absent only on an `error` answering a line that could not be read far
    /// enough to find one.
    public var requestID: String?

    // hello
    public var supportedVersions: [Int]?
    public var peer: ToolPeer?
    public var tools: [String]?
    public var maxConcurrentCalls: Int?
    public var maxFrameBytes: Int?

    // call
    public var tool: String?
    public var args: JSONValue?

    /// call and result
    public var attachments: [ToolAttachmentReference]?

    /// result
    public var content: [ToolContent]?

    /// error
    public var error: ToolErrorPayload?

    public init(protocolVersion: Int = ToolProtocol.version, type: ToolFrameType, requestID: String?) {
        self.protocolVersion = protocolVersion
        self.type = type
        self.requestID = requestID
    }

    public static func error(
        _ code: ToolErrorCode,
        _ message: String,
        requestID: String?,
        protocolVersion: Int = ToolProtocol.version,
    ) -> ToolFrame {
        var frame = ToolFrame(protocolVersion: protocolVersion, type: .error, requestID: requestID)
        frame.error = ToolErrorPayload(code: code, message: message)
        return frame
    }

    /// Whether a request ID is acceptable: non-empty, bounded, printable
    /// ASCII with no space.
    public static func isValidRequestID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        return !bytes.isEmpty && bytes.count <= ToolProtocol.maxRequestIDBytes
            && bytes.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }
}

public enum ToolFrameCodec {
    /// One line, newline included. Keys are sorted so frames are comparable
    /// in logs and tests.
    public static func encode(_ frame: ToolFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(frame)
        data.append(0x0A)
        return data
    }

    /// A line without its newline.
    public static func decode(_ line: Data) throws -> ToolFrame {
        try JSONDecoder().decode(ToolFrame.self, from: line)
    }
}
