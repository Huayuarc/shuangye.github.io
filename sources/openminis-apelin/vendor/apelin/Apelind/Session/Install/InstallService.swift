import Foundation

/// The install service as the bridge sees it: irisind's external operations
/// (Irisin's Documentation/ExternalClients.md). `IrisinInstallService` is the
/// real one, over the vendored IrisinExternalClient; the harness drives the
/// bridge with a fake.
protocol InstallService: Sendable {
    func serviceInfo() async throws -> InstallServiceInfo
    /// `sha256` is 64 lowercase hex digits. The descriptor stays the caller's.
    func submitInstall(transaction: UUID, descriptor: Int32, sha256: String) async throws -> InstallTransactionStatus
    func removePackage(transaction: UUID, packageID: String) async throws -> InstallTransactionStatus
    func respring(transaction: UUID) async throws -> InstallTransactionStatus
    func status(of transaction: UUID) async throws -> InstallTransactionStatus
    func events(
        of transaction: UUID,
        after: UInt64,
    ) async throws -> (status: InstallTransactionStatus, events: [InstallTransactionEvent])
}

struct InstallServiceInfo: Equatable, Sendable {
    var externalVersion: UInt64
    var capabilities: Set<String>
    var installRoot: String
}

enum InstallTransactionState: String, Codable, Sendable {
    case running, succeeded, failed, interrupted

    var isFinished: Bool {
        self != .running
    }
}

struct InstallTransactionStatus: Equatable, Sendable {
    var transaction: UUID
    var kind: String
    var state: InstallTransactionState
    var nextSequence: UInt64
    var exitStatus: Int64?
    var packageID: String?
    var version: String?
    var failure: String?
    var failureText: String?
    var duplicate: Bool
}

struct InstallTransactionEvent: Equatable, Sendable {
    var sequence: UInt64
    var kind: String
    var text: String
    var phase: String?
    var step: String?
    var packageID: String?
    var version: String?
    var completed: Int64?
    var total: Int64?
    var exitStatus: Int64?
    var problem: String?
}

struct InstallServiceError: Error, Equatable, CustomStringConvertible {
    enum Code: Equatable, Sendable {
        /// Not installed, not started yet, or refused this program.
        case unavailable
        /// The connection dropped; ask again.
        case interrupted
        /// An Irisin before 4.7: no external operations.
        case tooOld
        case notFound
        /// The transaction ID is taken by a different request.
        case conflict
        case refused
    }

    var code: Code
    var message: String

    init(_ code: Code, _ message: String = "") {
        self.code = code
        self.message = message
    }

    var isTransient: Bool {
        code == .unavailable || code == .interrupted
    }

    var description: String {
        message.isEmpty ? "\(code)" : "\(code): \(message)"
    }
}

/// What the bridge needs of the installed service.
enum InstallServiceRequirement {
    static let minimumIrisin = "4.7.3"
    static let capabilities: Set<String> = [
        "submitInstall",
        "transactionStatus",
        "transactionEvents",
        "removePackage",
        "respring",
    ]
}
