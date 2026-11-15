import Foundation
import CryptoKit

public enum NativeError: Error, Equatable {
    case denied(String)
    case disconnected
    case protocolViolation
    case unsupportedPlatform
}

func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func randomBytes() -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}
func authenticate<T: Encodable>(_ value: T, key: Data) throws -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: try canonical(value), using: SymmetricKey(data: key)))
}
func verify<T: Encodable>(_ tag: Data, value: T, key: Data) throws -> Bool {
    HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try canonical(value), using: SymmetricKey(data: key))
}

/// Trusted launch configuration, never populated from model tool arguments.
public struct ProjectRegistration: Codable {
    public let id: String
    public let root: String
    public init(id: String, root: String) { self.id = id; self.root = root }
}

public enum NativeOperation: String, Codable {
    case hostEnvironment
    case createMarker
}

/// Derived from the authenticated service challenge, never accepted as request risk flags.
public struct ServiceFacts: Equatable {
    public let operation: NativeOperation
    public let requiresAsk: Bool
    public let canonicalRoot: String
    public let descriptionDigest: String
    public let markerName: String?
}

public struct Call: Codable, Equatable {
    public let session: String
    public let project: String
    public let tool: String
    /// This minimal service permits only the registered canonical root as cwd.
    public let cwd: String
    public let descriptionDigest: String
    public init(session: String, project: String, operation: NativeOperation, cwd: String, descriptionDigest: String) {
        self.init(session: session, project: project, tool: operation.rawValue, cwd: cwd, descriptionDigest: descriptionDigest)
    }
    public init(session: String, project: String, tool: String, cwd: String, descriptionDigest: String) {
        self.session = session; self.project = project; self.tool = tool
        self.cwd = cwd; self.descriptionDigest = descriptionDigest
    }
}

public struct Challenge: Codable, Equatable {
    public let nonce: Data
    public let connection: Data
    public let call: Call
    public let canonicalRoot: String
    public let expiresAt: TimeInterval
    public let review: String
    /// Available on the marker-only challenge returned by the service.
    public var facts: ServiceFacts? {
        guard let operation = NativeOperation(rawValue: call.tool) else { return nil }
        return ServiceFacts(operation: operation, requiresAsk: operation == .createMarker,
            canonicalRoot: canonicalRoot, descriptionDigest: call.descriptionDigest,
            markerName: operation == .createMarker ? ".native-development-marker" : nil)
    }
}
public typealias ServiceReview = Challenge
public enum Decision: String, Codable { case allowOnce, deny }
struct DecisionBody: Codable {
    let domain: String
    let challenge: Challenge
    let decision: Decision
}
public struct SignedDecision: Codable {
    public let challenge: Challenge
    public let decision: Decision
    public let tag: Data
}

/// Keep exclusively in the trusted host approval adapter, outside tool/model dispatch.
public final class DecisionSigner {
    private let key: Data
    init(key: Data) { self.key = key }
    public func sign(_ challenge: Challenge, decision: Decision) throws -> SignedDecision {
        let body = DecisionBody(domain: "native-development.decision.v1", challenge: challenge, decision: decision)
        return SignedDecision(challenge: challenge, decision: decision, tag: try authenticate(body, key: key))
    }
}

public struct ServiceReply: Codable {
    public let challenge: Challenge?
    public let environment: [String: String]?
    public let markerCreated: Bool?
    public let error: String?
    init(challenge: Challenge? = nil, environment: [String: String]? = nil,
         markerCreated: Bool? = nil, error: String? = nil) {
        self.challenge = challenge; self.environment = environment
        self.markerCreated = markerCreated; self.error = error
    }
}
struct Bootstrap: Codable {
    let version: Int
    let connection: Data
    let transportKey: Data
    let decisionKey: Data
    let sessions: [String]
    let projects: [ProjectRegistration]
    let lifetime: TimeInterval
}
struct Request: Codable {
    let action: String
    var call: Call? = nil
    var decision: SignedDecision? = nil
    var nonce: Data? = nil
    var session: String? = nil
}
struct PacketBody: Codable {
    let domain: String
    let connection: Data
    let sequence: UInt64
    let payload: Data
}
struct Packet: Codable { let body: PacketBody; let tag: Data }
