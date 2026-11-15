import Foundation
import Darwin

final class RegisteredProject {
    let id: String
    let root: String
    let fd: Int32
    private let device: dev_t
    private let inode: ino_t
    init(_ registration: ProjectRegistration) throws {
        guard !registration.id.isEmpty, registration.root.hasPrefix("/") else { throw NativeError.denied("invalid registration") }
        let resolved = URL(fileURLWithPath: registration.root).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == registration.root else { throw NativeError.denied("root must already be canonical") }
        let descriptor = open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeError.denied("root unavailable") }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { Darwin.close(descriptor); throw NativeError.denied("root stat") }
        id = registration.id; root = resolved; fd = descriptor; device = info.st_dev; inode = info.st_ino
        _ = try descriptionDigest()
    }
    deinit { Darwin.close(fd) }
    func descriptionDigest() throws -> String {
        var current = stat()
        guard URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root,
              lstat(root, &current) == 0, current.st_dev == device, current.st_ino == inode,
              (current.st_mode & S_IFMT) == S_IFDIR else { throw NativeError.denied("root changed") }
        let description = openat(fd, "apelin-project.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard description >= 0 else { throw NativeError.denied("description unavailable") }
        defer { Darwin.close(description) }
        var before = stat()
        guard fstat(description, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= 1_048_576 else { throw NativeError.denied("description must be bounded regular file") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(description, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw NativeError.denied("description read") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 1_048_576 else { throw NativeError.denied("description too large") }
        }
        var after = stat()
        guard fstat(description, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["projectID"] as? String == id else {
            throw NativeError.denied("description changed or invalid JSON")
        }
        return digest(data)
    }
    func createMarker() throws {
        let marker = openat(fd, ".native-development-marker", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard marker >= 0 else { throw NativeError.denied("marker already exists or unavailable") }
        Darwin.close(marker)
    }
}

/// One engine per inherited connection. The service loop serializes all ledger transitions.
final class ServiceEngine {
    let bootstrap: Bootstrap
    private let projects: [String: RegisteredProject]
    private var sessions: Set<String>
    private var pending: [Data: Challenge] = [:]
    private var terminated = false
    init(_ bootstrap: Bootstrap) throws {
        guard bootstrap.version == 1, bootstrap.connection.count == 32,
              bootstrap.transportKey.count == 32, bootstrap.decisionKey.count == 32,
              bootstrap.lifetime > 0, bootstrap.lifetime <= 60,
              !bootstrap.sessions.isEmpty, bootstrap.sessions.allSatisfy({ !$0.isEmpty }) else {
            throw NativeError.protocolViolation
        }
        var registry: [String: RegisteredProject] = [:]
        for registration in bootstrap.projects {
            guard registry[registration.id] == nil else { throw NativeError.denied("duplicate project") }
            registry[registration.id] = try RegisteredProject(registration)
        }
        self.bootstrap = bootstrap; projects = registry; sessions = Set(bootstrap.sessions)
    }
    func disconnect() { terminated = true; pending.removeAll(); sessions.removeAll() }
    private func validate(_ call: Call) throws -> RegisteredProject {
        guard !terminated, sessions.contains(call.session), let project = projects[call.project],
              call.cwd == project.root, call.descriptionDigest == (try project.descriptionDigest()),
              call.tool == "hostEnvironment" || call.tool == "createMarker" else {
            throw NativeError.denied("unregistered context, changed description or unknown operation")
        }
        return project
    }
    func handle(_ request: Request, live: () throws -> Void) throws -> ServiceReply {
        guard !terminated else { throw NativeError.disconnected }
        switch request.action {
        case "prepare":
            guard request.call != nil, request.decision == nil, request.nonce == nil, request.session == nil else { throw NativeError.protocolViolation }
        case "decide":
            guard request.call == nil, request.decision != nil, request.nonce == nil, request.session == nil else { throw NativeError.protocolViolation }
        case "cancel":
            guard request.call == nil, request.decision == nil, request.nonce != nil, request.session == nil else { throw NativeError.protocolViolation }
        case "cancelSession":
            guard request.call == nil, request.decision == nil, request.nonce == nil, request.session != nil else { throw NativeError.protocolViolation }
        default: throw NativeError.denied("unknown action")
        }
        pending = pending.filter { $0.value.expiresAt > ProcessInfo.processInfo.systemUptime }
        switch request.action {
        case "prepare":
            guard let call = request.call else { throw NativeError.protocolViolation }
            let project = try validate(call)
            if call.tool == "hostEnvironment" {
                return ServiceReply(environment: ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                                                  "process": ProcessInfo.processInfo.processName])
            }
            guard pending.count < 256 else { throw NativeError.denied("too many pending approvals") }
            let challenge = Challenge(nonce: randomBytes(), connection: bootstrap.connection, call: call,
                canonicalRoot: project.root, expiresAt: ProcessInfo.processInfo.systemUptime + bootstrap.lifetime,
                review: "Create fixed empty .native-development-marker (0600, exclusive) in registered project root. Approval required for this call only.")
            pending[challenge.nonce] = challenge
            return ServiceReply(challenge: challenge)
        case "decide":
            guard let decision = request.decision else { throw NativeError.protocolViolation }
            // Remove before validation: any attempted redemption burns the nonce, including a bad MAC.
            guard let stored = pending.removeValue(forKey: decision.challenge.nonce), stored == decision.challenge,
                  stored.connection == bootstrap.connection, stored.expiresAt > ProcessInfo.processInfo.systemUptime,
                  try verify(decision.tag, value: DecisionBody(domain: "native-development.decision.v1", challenge: stored,
                                                             decision: decision.decision), key: bootstrap.decisionKey),
                  decision.decision == .allowOnce else { throw NativeError.denied("invalid, denied, expired or spent decision") }
            let project = try validate(stored.call)
            try live()
            try project.createMarker()
            return ServiceReply(markerCreated: true)
        case "cancel":
            guard let nonce = request.nonce else { throw NativeError.protocolViolation }
            pending.removeValue(forKey: nonce)
            return ServiceReply()
        case "cancelSession":
            guard let session = request.session else { throw NativeError.protocolViolation }
            sessions.remove(session)
            pending = pending.filter { $0.value.call.session != session }
            return ServiceReply()
        default: throw NativeError.denied("unknown action")
        }
    }
}

public enum NativeService {
    /// Descriptor must be inherited from the private launcher; no named listening endpoint exists.
    public static func run(inheritedDescriptor: Int32) throws {
        #if os(macOS)
        let socket = try FramedSocket(inheritedDescriptor)
        defer { socket.dispose() }
        let bootstrap = try socket.receive(Bootstrap.self)
        let engine = try ServiceEngine(bootstrap)
        defer { engine.disconnect() }
        let channel = AuthenticatedChannel(socket: socket, bootstrap: bootstrap, host: false)
        try channel.send(ServiceReply(environment: ["protocol": "1"]))
        while true {
            let request = try channel.receive(Request.self)
            let reply: ServiceReply
            do { reply = try engine.handle(request, live: socket.requireLive) }
            catch let error as NativeError {
                if error == .protocolViolation || error == .disconnected { throw error }
                reply = ServiceReply(error: String(describing: error))
            } catch { reply = ServiceReply(error: "operation refused") }
            try channel.send(reply)
        }
        #else
        throw NativeError.unsupportedPlatform
        #endif
    }
}
