import ApelinProtocol
import Darwin
import Dispatch
import Foundation

// libSystem's posix_spawn credential SPI, present on every iOS this app
// supports (spawn_private.h). It sets the child's identity in the kernel
// before exec, so the child never runs a line as root.

@_silgen_name("posix_spawnattr_set_uid_np")
func spawnSetUID(_ attributes: UnsafeMutablePointer<posix_spawnattr_t?>, _ uid: uid_t) -> Int32

@_silgen_name("posix_spawnattr_set_gid_np")
func spawnSetGID(_ attributes: UnsafeMutablePointer<posix_spawnattr_t?>, _ gid: gid_t) -> Int32

@_silgen_name("posix_spawnattr_set_groups_np")
func spawnSetGroups(
    _ attributes: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ count: Int32,
    _ groups: UnsafeMutablePointer<gid_t>,
    _ membershipUID: uid_t,
) -> Int32

@_silgen_name("proc_pidinfo")
private func spawnProcPIDInfo(
    _ pid: Int32,
    _ flavor: Int32,
    _ argument: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int32,
) -> Int32

/// Who a spawned process runs as.
struct SpawnIdentity {
    var uid: uid_t
    var gid: gid_t

    static let mobile = SpawnIdentity(uid: uid_t(WorkerRole.mobileUID), gid: gid_t(WorkerRole.mobileGID))
}

/// A running process's effective, real and saved uid and gid, from the
/// kernel (`proc_pidinfo(PROC_PIDTBSDINFO)`; `struct proc_bsdinfo` is 136
/// bytes with the six ids from offset 20, the same on macOS and iOS).
struct ProcessCredentials {
    var uid: uid_t
    var gid: gid_t
    var realUID: uid_t
    var realGID: gid_t
    var savedUID: uid_t
    var savedGID: gid_t

    init?(pid: pid_t) {
        let infoSize: Int32 = 136 // struct proc_bsdinfo
        let bsdInfoFlavor: Int32 = 3 // PROC_PIDTBSDINFO
        var buffer = [UInt8](repeating: 0, count: Int(infoSize))
        let size = buffer.withUnsafeMutableBytes { spawnProcPIDInfo(pid, bsdInfoFlavor, 0, $0.baseAddress, infoSize) }
        guard size == infoSize else { return nil }
        func id(_ offset: Int) -> UInt32 {
            buffer.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        }
        uid = id(20); gid = id(24); realUID = id(28); realGID = id(32); savedUID = id(36); savedGID = id(40)
    }

    /// Every one of the six is the identity's: nothing left to regain root with.
    func matches(_ identity: SpawnIdentity) -> Bool {
        [uid, realUID, savedUID].allSatisfy { $0 == identity.uid }
            && [gid, realGID, savedGID].allSatisfy { $0 == identity.gid }
    }
}

/// Kills `pid` unless the kernel says it runs as `identity`. The privilege
/// drop is set before exec; this is the check that it took.
func verifyDropped(_ pid: pid_t, to identity: SpawnIdentity) throws {
    guard let credentials = ProcessCredentials(pid: pid), credentials.matches(identity) else {
        kill(pid, SIGKILL)
        throw SpawnError.privilegesKept(pid)
    }
}

enum SpawnError: Error, CustomStringConvertible {
    case untrustedExecutable(String)
    case failed
    case privilegesKept(pid_t)

    var description: String {
        switch self {
        case let .untrustedExecutable(path):
            "\(path) is missing or its permissions have changed. Reinstall Apelin with your preferred package manager, then try again."
        case .failed: "Apelin could not start a background process. Try again."
        case let .privilegesKept(pid):
            "Process \(pid) kept elevated privileges instead of running as its own user, so it was terminated."
        }
    }
}

/// Starts `path` with `channel` as its descriptor 3, /dev/null on 0–2 and
/// every other descriptor closed (`POSIX_SPAWN_CLOEXEC_DEFAULT`), signals
/// reset, and — for `identity` — uid, gid and groups set before exec. The
/// executable must be root-owned and writable by nobody else, checked on its
/// canonical path. Returns the pid; the caller reaps it.
func spawnProcess(
    path: String,
    arguments: [String],
    environment: [String],
    channel: Int32,
    identity: SpawnIdentity?,
) throws -> pid_t {
    guard let canonical = canonicalPath(path), isRootOwnedExecutable(canonical) else {
        throw SpawnError.untrustedExecutable(path)
    }

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }

    for descriptor: Int32 in 0 ... 2 {
        posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
    }
    posix_spawn_file_actions_adddup2(&actions, channel, 3)

    var everySignal = sigset_t()
    var noSignal = sigset_t()
    sigfillset(&everySignal)
    sigemptyset(&noSignal)
    posix_spawnattr_setsigdefault(&attributes, &everySignal)
    posix_spawnattr_setsigmask(&attributes, &noSignal)
    let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    posix_spawnattr_setflags(&attributes, flags)

    if let identity {
        var groups = [identity.gid]
        try requireSpawnStep("set groups", spawnSetGroups(&attributes, 1, &groups, identity.uid))
        try requireSpawnStep("set gid", spawnSetGID(&attributes, identity.gid))
        try requireSpawnStep("set uid", spawnSetUID(&attributes, identity.uid))
    }

    var pid: pid_t = 0
    let status = withCStrings(arguments) { argv in
        withCStrings(environment) { envp in
            posix_spawn(&pid, canonical, &actions, &attributes, argv, envp)
        }
    }
    try requireSpawnStep("posix_spawn \(canonical)", status)
    if let identity {
        do {
            try verifyDropped(pid, to: identity)
        } catch {
            var ignored: Int32 = 0
            waitpid(pid, &ignored, 0)
            throw error
        }
    }
    return pid
}

/// Throws `.failed` for a nonzero `status`, logging the step and the error
/// first: the spawn calls return their error code and do not set `errno`.
private func requireSpawnStep(_ step: String, _ status: Int32) throws {
    guard status != 0 else { return }
    NSLog("%@: %@: %@", String(cString: getprogname()), step, String(cString: strerror(status)))
    throw SpawnError.failed
}

/// Reaps `pid` when it exits and reports its wait status on `queue`.
func reapWhenExited(_ pid: pid_t, queue: DispatchQueue, _ exited: @escaping (Int32) -> Void) {
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
    var reaped = false
    let reap = {
        guard !reaped else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        reaped = true
        source.cancel()
        exited(status)
    }
    source.setEventHandler(handler: reap)
    source.activate()
    // A child that exited before the source was armed raises no event.
    queue.async(execute: reap)
}

/// Root-owned, a regular file, owner-executable, not group- or world-writable.
func isRootOwnedExecutable(_ path: String) -> Bool {
    var metadata = stat()
    guard stat(path, &metadata) == 0 else { return false }
    return metadata.st_uid == 0
        && metadata.st_mode & S_IFMT == S_IFREG
        && metadata.st_mode & S_IXUSR != 0
        && metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
}

private func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
