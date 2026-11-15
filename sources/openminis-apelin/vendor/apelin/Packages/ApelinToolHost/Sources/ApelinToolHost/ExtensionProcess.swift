import ApelinToolCore
import Darwin
import Foundation

/// libSystem's posix_spawn credential SPI (spawn_private.h), on every iOS
/// this package supports: the child's identity is set in the kernel before
/// exec, so an extension never runs a line as root.
@_silgen_name("posix_spawnattr_set_uid_np")
private func toolSpawnSetUID(_ attributes: UnsafeMutablePointer<posix_spawnattr_t?>, _ uid: uid_t) -> Int32
@_silgen_name("posix_spawnattr_set_gid_np")
private func toolSpawnSetGID(_ attributes: UnsafeMutablePointer<posix_spawnattr_t?>, _ gid: gid_t) -> Int32
@_silgen_name("posix_spawnattr_set_groups_np")
private func toolSpawnSetGroups(
    _ attributes: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ count: Int32,
    _ groups: UnsafeMutablePointer<gid_t>,
    _ membershipUID: uid_t,
) -> Int32
@_silgen_name("proc_pidinfo")
private func toolProcPIDInfo(
    _ pid: Int32,
    _ flavor: Int32,
    _ argument: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int32,
) -> Int32

/// Who a root caller spawns an extension as (mobile: 501/501).
public struct ToolProcessIdentity: Hashable, Sendable {
    public var uid: uid_t
    public var gid: gid_t

    public init(uid: uid_t, gid: gid_t) {
        self.uid = uid
        self.gid = gid
    }

    public static let mobile = ToolProcessIdentity(uid: 501, gid: 501)

    /// Whether the kernel says `pid` runs as this identity: effective, real
    /// and saved uid and gid (`struct proc_bsdinfo`, ids from offset 20).
    func isHeld(by pid: pid_t) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 136)
        guard buffer.withUnsafeMutableBytes({ toolProcPIDInfo(pid, 3, 0, $0.baseAddress, 136) }) == 136 else {
            return false
        }
        let ids = (0 ..< 6).map { index in
            buffer.withUnsafeBytes { $0.load(fromByteOffset: 20 + index * 4, as: UInt32.self) }
        }
        return ids[0] == uid && ids[2] == uid && ids[4] == uid && ids[1] == gid && ids[3] == gid && ids[5] == gid
    }
}

/// A spawned extension and the host's ends of its four descriptors: stdin,
/// stdout, stderr, and the attachment socket at descriptor 3.
///
/// Spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT`, so the child inherits those
/// four and nothing else the host has open; with default signal dispositions
/// and an empty mask; in its own process group; with only the environment it
/// is given.
struct ExtensionProcess {
    let pid: pid_t
    let stdinWrite: Int32
    let stdoutRead: Int32
    let stderrRead: Int32
    let attachmentSocket: Int32

    enum Failure: Error, CustomStringConvertible {
        case system(String, Int32)
        case refusedAsRoot
        case privilegesKept

        var description: String {
            switch self {
            case let .system(call, code): "\(call): \(String(cString: strerror(code)))"
            case .refusedAsRoot: "extensions run as mobile, never as root"
            case .privilegesKept:
                "the extension kept elevated privileges instead of running as its own user, so it was terminated"
            }
        }
    }

    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        allowRoot: Bool,
        runAs: ToolProcessIdentity?,
    ) throws -> ExtensionProcess {
        let dropTo = runAs.flatMap { $0.uid != 0 && geteuid() == 0 ? $0 : nil }
        guard allowRoot || dropTo != nil || geteuid() != 0 else { throw Failure.refusedAsRoot }

        var opened: [Int32] = []
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw Failure.system("pipe", errno) }
            for fd in fds {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            }
            opened += fds
            return (fds[0], fds[1])
        }
        do {
            let input = try makePipe()
            let output = try makePipe()
            let errors = try makePipe()
            let sockets = try ToolAttachmentChannel.makePair()
            opened += [sockets.0, sockets.1]

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, input.read, STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, output.write, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, errors.write, STDERR_FILENO)
            posix_spawn_file_actions_adddup2(&actions, sockets.1, ToolProtocol.attachmentDescriptor)

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var allSignals = sigset_t()
            sigfillset(&allSignals)
            var noSignals = sigset_t()
            sigemptyset(&noSignals)
            posix_spawnattr_setsigdefault(&attributes, &allSignals)
            posix_spawnattr_setsigmask(&attributes, &noSignals)
            posix_spawnattr_setpgroup(&attributes, 0)
            let flags = POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setflags(&attributes, Int16(flags))
            if let dropTo {
                var groups = [dropTo.gid]
                guard toolSpawnSetGroups(&attributes, 1, &groups, dropTo.uid) == 0 else {
                    throw Failure.system("set groups", errno)
                }
                guard toolSpawnSetGID(&attributes, dropTo.gid) == 0 else { throw Failure.system("set gid", errno) }
                guard toolSpawnSetUID(&attributes, dropTo.uid) == 0 else { throw Failure.system("set uid", errno) }
            }

            var environment = environment
            environment[ToolProtocol.attachmentEnvironmentKey] = String(ToolProtocol.attachmentDescriptor)
            environment[ToolProtocol.protocolEnvironmentKey] = String(ToolProtocol.version)
            let argv = ([executable] + arguments).map { strdup($0) } + [nil]
            let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }

            var pid: pid_t = 0
            let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            guard status == 0 else { throw Failure.system("posix_spawn \(executable)", status) }
            if let dropTo, !dropTo.isHeld(by: pid) {
                kill(pid, SIGKILL)
                var ignored: Int32 = 0
                waitpid(pid, &ignored, 0)
                throw Failure.privilegesKept
            }

            close(input.read)
            close(output.write)
            close(errors.write)
            close(sockets.1)
            return ExtensionProcess(
                pid: pid,
                stdinWrite: input.write,
                stdoutRead: output.read,
                stderrRead: errors.read,
                attachmentSocket: sockets.0,
            )
        } catch {
            opened.forEach { close($0) }
            throw error
        }
    }
}

/// How a process ended.
public enum ExtensionExit: Hashable, Sendable, CustomStringConvertible {
    case exited(Int32)
    case signalled(Int32)

    init(waitStatus status: Int32) {
        // WIFEXITED / WEXITSTATUS / WTERMSIG are macros Swift does not import.
        let low = status & 0x7F
        if low == 0 {
            self = .exited((status >> 8) & 0xFF)
        } else {
            self = .signalled(low)
        }
    }

    public var description: String {
        switch self {
        case let .exited(code): "exited with status \(code)"
        case let .signalled(signal): "killed by signal \(signal) (\(String(cString: strsignal(signal))))"
        }
    }
}
