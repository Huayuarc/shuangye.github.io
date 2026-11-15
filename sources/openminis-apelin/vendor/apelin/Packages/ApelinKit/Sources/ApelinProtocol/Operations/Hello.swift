/// `hello`: answered by apelind itself, never forwarded. The app is
/// privileged exactly when this answers; it is never a build flag.
public struct HelloRequest: OperationRequest {
    public typealias Response = HelloResponse
    public static let operation = AppOperation.hello
    public init() {}
}

public struct HelloResponse: Codable, Sendable, Equatable {
    /// The install root apelind derived from its own path: `/var/jb` on
    /// rootless, the jbroot on roothide, `/` for a rootful layout.
    public var installRoot: String
    /// The daemon's `Wire.protocolVersion`.
    public var protocolVersion: Int64
    /// Every operation the daemon knows, implemented or not.
    public var operations: [AppOperation]

    public init(
        installRoot: String,
        protocolVersion: Int64 = Wire.protocolVersion,
        operations: [AppOperation] = AppOperation.allCases,
    ) {
        self.installRoot = installRoot
        self.protocolVersion = protocolVersion
        self.operations = operations
    }
}

public extension ApelinService {
    func hello() async throws -> HelloResponse {
        try await send(HelloRequest())
    }
}
