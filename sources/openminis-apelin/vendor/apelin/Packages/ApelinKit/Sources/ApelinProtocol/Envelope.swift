import ApelinCore
import Foundation

/// The versioned envelope every request and reply travels in, whatever the
/// transport: an XPC dictionary between the app and apelind
/// (`Shared/Protocol/XPCEnvelope.swift`), a `WorkerChannel` frame between
/// apelind, its session host and the workers.
public enum Wire {
    /// Raised when the envelope or any request/response changes
    /// incompatibly. v1 was the scaffold's bare `hello`.
    public static let protocolVersion: Int64 = 2

    // XPC dictionary keys.
    public static let operationKey = "op"
    public static let protocolVersionKey = "protocolVersion"
    public static let requestIDKey = "requestID"
    public static let payloadKey = "payload"
    public static let descriptorsKey = "fds"
    public static let okKey = "ok"
    public static let errorKey = "error"
    public static let errorCodeKey = "code"
    public static let errorMessageKey = "message"
    public static let errorReasonKey = "reason"
}

/// A request: the operation, the sender's protocol version, an ID echoed in
/// the reply, and the JSON-encoded request.
public struct WireRequest: Sendable, Equatable {
    public var operation: AppOperation
    public var protocolVersion: Int64
    public var requestID: String
    public var payload: Data

    public init(
        operation: AppOperation,
        protocolVersion: Int64 = Wire.protocolVersion,
        requestID: String = UUID().uuidString,
        payload: Data,
    ) {
        self.operation = operation
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.payload = payload
    }

    public init<R: OperationRequest>(_ request: R) throws {
        try self.init(operation: R.operation, payload: JSONCoding.encode(request))
    }

    public func decode<R: OperationRequest>(_: R.Type) throws -> R {
        guard operation == R.operation else {
            throw ApelinError(.badRequest, "\(operation.rawValue) does not decode as \(R.operation.rawValue)")
        }
        do {
            return try JSONCoding.decode(R.self, from: payload)
        } catch {
            throw ApelinError(.badRequest, "\(operation.rawValue): \(error)")
        }
    }
}

/// A reply: success with the JSON-encoded response, or an error.
public struct WireReply: Sendable, Equatable {
    public var requestID: String
    public var result: Result<Data, ApelinError>

    public init(requestID: String, result: Result<Data, ApelinError>) {
        self.requestID = requestID
        self.result = result
    }

    public static func success(_ requestID: String, _ value: some Encodable) -> WireReply {
        do {
            return try WireReply(requestID: requestID, result: .success(JSONCoding.encode(value)))
        } catch {
            return WireReply(
                requestID: requestID,
                result: .failure(ApelinError(.internal, "encoding the reply: \(error)")),
            )
        }
    }

    public static func failure(_ requestID: String, _ error: ApelinError) -> WireReply {
        WireReply(requestID: requestID, result: .failure(error))
    }
}

/// The error half of every reply.
public struct ApelinError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        /// The operation exists on the wire but nobody has written it yet.
        case unimplemented
        /// The payload does not decode, or a field is out of range.
        case badRequest
        /// The peer does not know the operation name.
        case unknownOperation
        /// The peers speak different protocol versions.
        case unsupportedVersion
        /// The caller may not do this (role, scope, grant, approval).
        case denied
        case notFound
        case conflict
        case cancelled
        case timeout
        /// No privileged backend answered: the app is on its own.
        case backendUnavailable
        /// The session host or a worker could not be reached or started.
        case unavailable
        case `internal`
    }

    /// What a refusal means beyond its code, for a caller that acts on it;
    /// the message stays text for people. Open-ended, so a reason a peer
    /// does not know still decodes.
    public struct Reason: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// `agentRunCode`, `denied`: the host's preset rule does not count
        /// a call sent as a preset; the agent asks the user instead.
        public static let notAPreset = Reason(rawValue: "notAPreset")
        /// `denied`: a remote or GitHub's API asked for a sign-in and no
        /// credential is saved for its host, or it refused the one it was
        /// given; the agent names Settings ▸ Git.
        public static let authenticationRequired = Reason(rawValue: "authenticationRequired")
    }

    public var code: Code
    public var message: String
    /// Absent on the wire when nil.
    public var reason: Reason?

    public init(_ code: Code, _ message: String = "", reason: Reason? = nil) {
        self.code = code
        self.message = message
        self.reason = reason
    }

    public static func unimplemented(_ operation: AppOperation) -> ApelinError {
        ApelinError(.unimplemented, "\(operation.rawValue) is not implemented yet")
    }

    public var description: String {
        message.isEmpty ? code.rawValue : "\(code.rawValue): \(message)"
    }
}
