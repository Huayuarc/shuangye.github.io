import ApelinCore

// Agent tool extensions: separate packages whose executables the session host
// starts as mobile from their installed manifest, after its own checks.
// Served by the session host (Apelind/Dispatch/ToolHostHandler.swift);
// the extension protocol lives in Packages/ApelinToolHost.
//
// Files travel as descriptors beside the envelope, both ways, never as a
// path: a call's `attachments` name slots in the request's descriptor list,
// a response's name slots in the reply's. The host relays neither descriptor
// it was given: it copies the bytes into a file of its own, unlinked at once,
// and passes a read-only descriptor to that, so the receiver can neither
// write the sender's file nor see it change.

public enum ToolRisk: String, Codable, Sendable {
    case readOnly
    case writesProject
    case system
}

public struct ToolDescriptor: Codable, Sendable, Equatable {
    public var name: String
    public var summary: String
    /// JSON Schema of the arguments, as `AgentTool` takes it.
    public var schema: JSONValue
    /// As the host classified it, not as the extension declared it.
    public var risk: ToolRisk

    public init(name: String, summary: String, schema: JSONValue, risk: ToolRisk) {
        self.name = name
        self.summary = summary
        self.schema = schema
        self.risk = risk
    }
}

public struct ToolHostOpenRequest: OperationRequest {
    public typealias Response = ToolHostOpenResponse
    public static let operation = AppOperation.toolHostOpen
    /// The extension's manifest ID.
    public var id: String
    public init(id: String) {
        self.id = id
    }
}

public struct ToolHostOpenResponse: Codable, Sendable, Equatable {
    public var sessionID: String
    public var tools: [ToolDescriptor]

    public init(sessionID: String, tools: [ToolDescriptor] = []) {
        self.sessionID = sessionID
        self.tools = tools
    }
}

public struct ToolHostCloseRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.toolHostClose
    public var sessionID: String
    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

/// A file sent with a call: a descriptor in the request's list, read whole
/// by the host before the call. At most `maximumAttachments`, each a regular
/// file of at most `maximumAttachmentBytes`.
public struct ToolHostAttachmentSlot: Codable, Sendable, Equatable {
    public var descriptor: DescriptorSlot
    /// The argument the file stands in for (`binary` for the disassembler),
    /// so the tool reads the descriptor instead of opening a path.
    public var argument: String?
    public var mimeType: String?
    /// For the tool to show; never opened.
    public var name: String?

    public init(descriptor: DescriptorSlot, argument: String? = nil, mimeType: String? = nil, name: String? = nil) {
        self.descriptor = descriptor
        self.argument = argument
        self.mimeType = mimeType
        self.name = name
    }
}

/// A file a tool returned: a read-only descriptor in the reply's list, to an
/// unlinked copy the host made.
public struct ToolHostAttachment: Codable, Sendable, Equatable {
    public var descriptor: DescriptorSlot
    public var name: String?
    public var mimeType: String?
    public var byteCount: Int
    /// `sha256:<hex>` of the bytes behind the descriptor, so a caller that
    /// keeps no descriptors (the console) can still tell what came back.
    public var sha256: String

    public init(
        descriptor: DescriptorSlot,
        name: String? = nil,
        mimeType: String? = nil,
        byteCount: Int,
        sha256: String,
    ) {
        self.descriptor = descriptor
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// One call to a tool of an open extension session. The host checks the tool
/// is one the manifest declares, and answers what the extension returned.
public struct ToolHostCallRequest: OperationRequest {
    public typealias Response = ToolHostCallResponse
    public static let operation = AppOperation.toolHostCall
    /// The tool protocol's own bounds (`ToolProtocolLimits`).
    public static let maximumAttachments = 8
    public static let maximumAttachmentBytes = 32 << 20

    public var sessionID: String
    public var tool: String
    public var arguments: JSONValue
    /// Capped by the extension's manifest and the protocol's maximum.
    public var timeoutSeconds: Double?
    public var attachments: [ToolHostAttachmentSlot]

    public init(
        sessionID: String,
        tool: String,
        arguments: JSONValue = .object([:]),
        timeoutSeconds: Double? = nil,
        attachments: [ToolHostAttachmentSlot] = [],
    ) {
        self.sessionID = sessionID
        self.tool = tool
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        tool = try container.decode(String.self, forKey: .tool)
        arguments = try container.decodeIfPresent(JSONValue.self, forKey: .arguments) ?? .object([:])
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        attachments = try container.decodeIfPresent([ToolHostAttachmentSlot].self, forKey: .attachments) ?? []
    }
}

public struct ToolHostCallResponse: Codable, Sendable, Equatable {
    /// The text parts of the result, joined.
    public var text: String
    /// The files the tool returned, in its order.
    public var attachments: [ToolHostAttachment]
    /// The extension's error, when the call failed: `{code, message}`.
    public var error: JSONValue?

    public init(text: String, attachments: [ToolHostAttachment] = [], error: JSONValue? = nil) {
        self.text = text
        self.attachments = attachments
        self.error = error
    }
}

/// A file to send with `toolHostCall(_:files:)`.
public struct ToolHostOutgoingFile: Sendable {
    public var descriptor: OwnedDescriptor
    public var argument: String?
    public var mimeType: String?
    public var name: String?

    public init(descriptor: OwnedDescriptor, argument: String? = nil, mimeType: String? = nil, name: String? = nil) {
        self.descriptor = descriptor
        self.argument = argument
        self.mimeType = mimeType
        self.name = name
    }
}

/// A file a tool returned, with its descriptor owned by the caller.
public struct ToolHostReceivedFile: Sendable {
    public var attachment: ToolHostAttachment
    public var descriptor: OwnedDescriptor
}

public extension ApelinService {
    /// A call that sends no files; any the tool returns are closed unread.
    func toolHostCall(_ request: ToolHostCallRequest) async throws -> ToolHostCallResponse {
        try await send(request)
    }

    /// A call with files both ways: `files` go out as descriptors 0…n−1 (the
    /// request's own `attachments` are replaced), and each file the tool
    /// returned comes back with its read-only descriptor.
    func toolHostCall(
        _ request: ToolHostCallRequest,
        files: [ToolHostOutgoingFile],
    ) async throws -> (ToolHostCallResponse, [ToolHostReceivedFile]) {
        var request = request
        request.attachments = files.indices.map {
            ToolHostAttachmentSlot(
                descriptor: DescriptorSlot(index: $0),
                argument: files[$0].argument,
                mimeType: files[$0].mimeType,
                name: files[$0].name,
            )
        }
        let (response, descriptors) = try await sendReturningDescriptors(request, descriptors: files.map(\.descriptor))
        let received = try response.attachments.map { attachment -> ToolHostReceivedFile in
            guard descriptors.indices.contains(attachment.descriptor.index) else {
                throw ApelinError(.internal, "toolHostCall answered an attachment with no descriptor")
            }
            return ToolHostReceivedFile(attachment: attachment, descriptor: descriptors[attachment.descriptor.index])
        }
        return (response, received)
    }

    func toolHostOpen(id: String) async throws -> ToolHostOpenResponse {
        try await send(ToolHostOpenRequest(id: id))
    }

    func toolHostClose(sessionID: String) async throws {
        _ = try await send(ToolHostCloseRequest(sessionID: sessionID))
    }
}
