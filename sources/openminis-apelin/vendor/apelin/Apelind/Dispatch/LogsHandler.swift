import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// Logs and crash reports. A log stream is a task served by apelin-diagnostics
/// (icli, as mobile); only when that worker says it cannot read the live log
/// (`denied`) does the host start apelin-log-reader, as root, with the same
/// fixed filter. Crash reports are listed and symbolicated by
/// apelin-diagnostics; `crashOpen` is the host's own: it opens a report by id
/// as root and hands back a read-only descriptor, to the app or to the
/// diagnostics worker for a report mobile cannot read.
enum LogsHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .logStream:
            await logStream(request, host: host)
        case .crashList, .crashSymbolicate:
            await host.forward(request, to: .diagnostics)
        case .crashOpen:
            CrashReports.open(request)
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a logs operation"))
        }
    }

    /// A call with `stream` reads on; one with `filter` opens a stream and
    /// answers its first batch.
    private static func logStream(_ request: HostRequest, host: SessionHost) async -> HostReply {
        let poll: LogStreamRequest
        do {
            poll = try request.decode(LogStreamRequest.self)
        } catch {
            return request.fail(error)
        }
        if poll.stream != nil {
            return await host.attach(request, LogStreamRequest.self)
        }
        guard poll.filter != nil else {
            return request.fail(ApelinError(.badRequest, "logStream needs a filter or a stream"))
        }
        var (reply, descriptors) = await host.startTask(request, kind: .logStream, role: .diagnostics)
        if case let .failure(error) = reply.result, error.code == .denied {
            (reply, descriptors) = await host.startTask(request, kind: .logStream, role: .logReader)
        }
        guard case let .success(payload) = reply.result else { return (reply, descriptors) }
        do {
            let handle = try JSONCoding.decode(TaskHandle.self, from: payload)
            let batch = try await host.registry.attach(
                handle.taskID,
                as: .logStream,
                afterSeq: .start,
                waitMilliseconds: poll.waitMilliseconds,
            )
            return (.success(request.requestID, batch), [])
        } catch {
            return request.fail(error)
        }
    }
}

/// Crash reports by id. An id is a report's file name — one component,
/// ending `.ips` or `.crash` — found directly inside one of the system's
/// crash report directories after `realpath(3)`.
enum CrashReports {
    /// icli's three, and the only places a report id is looked up.
    private static let directories = [
        "/var/mobile/Library/Logs/CrashReporter",
        "/var/mobile/Library/Logs/DiagnosticReports",
        "/var/mobile/Library/Logs/CrashReporter/Retired",
    ]
    private static let maximumBytes: Int64 = 16 * 1024 * 1024

    private static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !CanonicalPath.containsNUL(id) && !id.hasPrefix(".")
            && id.utf8.count <= 255 && (id.hasSuffix(".ips") || id.hasSuffix(".crash"))
    }

    /// The report's canonical path, if `id` names one.
    private static func path(for id: String) -> String? {
        guard isValidID(id) else { return nil }
        for directory in directories {
            guard let root = CanonicalPath.resolve(directory),
                  let path = CanonicalPath.resolve(root + "/" + id),
                  (path as NSString).deletingLastPathComponent == root
            else { continue }
            return path
        }
        return nil
    }

    static func open(_ request: HostRequest) -> HostReply {
        let crash: CrashOpenRequest
        do {
            crash = try request.decode(CrashOpenRequest.self)
        } catch {
            return request.fail(error)
        }
        guard isValidID(crash.id) else {
            return request.fail(ApelinError(.badRequest, "\(crash.id) is not a crash report id"))
        }
        guard let path = path(for: crash.id) else {
            return request.fail(ApelinError(.notFound, "no crash report \(crash.id)"))
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return request.fail(ApelinError(
                .notFound,
                "\(crash.id) cannot be opened: \(String(cString: strerror(errno)))",
            ))
        }
        let owned = OwnedDescriptor(adopting: descriptor)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            return request.fail(ApelinError(.badRequest, "\(crash.id) is not a regular file"))
        }
        guard metadata.st_size <= maximumBytes else {
            return request.fail(ApelinError(
                .badRequest,
                "\(crash.id) is larger than \(maximumBytes / (1024 * 1024)) MB",
            ))
        }
        return (
            .success(
                request.requestID,
                CrashOpenResponse(descriptor: DescriptorSlot(index: 0), size: Int64(metadata.st_size)),
            ),
            [owned],
        )
    }
}
