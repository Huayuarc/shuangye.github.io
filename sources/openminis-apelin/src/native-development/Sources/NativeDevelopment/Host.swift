import Foundation
import Darwin

/// Blocking RPC client. Its lock serializes request/reply pairs across host threads.
/// Run calls off MainActor. Cancellation closes the connection, invalidating all pending work.
public final class NativeConnection {
    private let channel: AuthenticatedChannel
    private let lock = NSLock()
    #if os(macOS)
    private let process: Process
    private init(channel: AuthenticatedChannel, process: Process) { self.channel = channel; self.process = process }
    #else
    private init(channel: AuthenticatedChannel) { self.channel = channel }
    #endif
    deinit { disconnect() }
    public func disconnect() { channel.socket.close() }
    private func rpc(_ request: Request) throws -> ServiceReply {
        lock.lock(); defer { lock.unlock() }
        do {
            try channel.send(request)
            let reply = try channel.receive(ServiceReply.self)
            if let error = reply.error { throw NativeError.denied(error) }
            return reply
        } catch let error as NativeError {
            if case .denied = error { throw error }
            disconnect(); throw error
        } catch { disconnect(); throw error }
    }
    public func prepare(_ call: Call) throws -> ServiceReply { try rpc(Request(action: "prepare", call: call)) }
    public func execute(_ decision: SignedDecision) throws -> ServiceReply { try decide(decision) }
    public func decide(_ decision: SignedDecision) throws -> ServiceReply { try rpc(Request(action: "decide", decision: decision)) }
    public func cancel(_ challenge: Challenge) throws { _ = try rpc(Request(action: "cancel", nonce: challenge.nonce)) }
    /// Permanently revokes this registered session on this connection.
    public func cancelSession(_ session: String) throws { _ = try rpc(Request(action: "cancelSession", session: session)) }

    /// Only the trusted host may supply registry/session data and choose the service executable.
    /// Credentials travel in the inherited private socket, never argv/environment/files.
    public static func connect(executable: URL, projects: [ProjectRegistration], sessions: [String],
                               challengeLifetime: TimeInterval = 30) throws -> (NativeConnection, DecisionSigner) {
        try launch(executable: executable, projects: projects, sessions: sessions, challengeLifetime: challengeLifetime)
    }

    public static func launch(executable: URL, projects: [ProjectRegistration], sessions: [String],
                              challengeLifetime: TimeInterval = 30) throws -> (NativeConnection, DecisionSigner) {
        #if os(macOS)
        guard executable.isFileURL, executable.path.hasPrefix("/") else { throw NativeError.denied("service path") }
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw NativeError.disconnected }
        // Process duplicates only the explicitly supplied standardInput into the child.
        guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
            throw NativeError.protocolViolation
        }
        let socket: FramedSocket
        do { socket = try FramedSocket(descriptors[0]) }
        catch { Darwin.close(descriptors[1]); throw error }
        let child = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--inherited-socket-stdin-v1"]
        process.standardInput = child
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = [:]
        do { try process.run() } catch { socket.close(); try? child.close(); throw error }
        try child.close()
        let bootstrap = Bootstrap(version: 1, connection: randomBytes(), transportKey: randomBytes(),
                                  decisionKey: randomBytes(), sessions: sessions, projects: projects, lifetime: challengeLifetime)
        let channel = AuthenticatedChannel(socket: socket, bootstrap: bootstrap, host: true)
        do {
            try socket.send(bootstrap)
            let reply = try channel.receive(ServiceReply.self)
            guard reply.environment?["protocol"] == "1" else { throw NativeError.protocolViolation }
        } catch { socket.close(); process.terminate(); throw error }
        return (NativeConnection(channel: channel, process: process), DecisionSigner(key: bootstrap.decisionKey))
        #else
        throw NativeError.unsupportedPlatform
        #endif
    }
}
