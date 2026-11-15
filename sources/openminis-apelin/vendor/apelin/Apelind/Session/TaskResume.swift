import ApelinCore
import ApelinProtocol
import Foundation

/// Starting a worker's task again after the session host restarted: a build
/// (`buildStart`) or an environment task (`toolchainSetup`, `sdkImport`,
/// `gitClone`, `transferExport`).
///
/// When the host accepts such a request, `plan` goes into the record's
/// `resume` before the worker sees it: the operation, its payload and who
/// asked. On the next launch `resume` writes a `resumed` event — numbering
/// goes on from the last event that survived — and sends the same request to
/// a new worker under the same task ID, marked `resumed`, so a build keeps
/// its build ID. The worker makes its operation idempotent: a build cleans
/// its folder and artifact record, an import its staging, a clone the folder
/// it made, toolchain setup goes on from its job record.
///
/// Never resumed, each ended with the reason: a task an agent session
/// started (the session ended with the old host, so nothing would read the
/// result), a task started with a descriptor (it closed with the old host),
/// one whose request names a URL with a user, password, query or fragment
/// in it (credentials are never written down), a transfer import (a project
/// it placed would be placed again), a toolchain removal (its
/// package step is an install task that resumes on its own), one cancelled
/// before the restart (it ends `cancelled`), and one already resumed
/// `maximumResumes` times, so a crash loop cannot keep apelind up. A task
/// the app started passes the host's checks again before it is resent.
struct TaskResume: Sendable {
    static let maximumResumes = 2
    static let operations: Set<AppOperation> = [.buildStart, .toolchainSetup, .sdkImport, .gitClone, .transferExport]

    /// What `resume` holds for these tasks. Nothing secret, no descriptor.
    struct Plan: Codable, Equatable {
        var operation: AppOperation
        /// The request's payload as it was accepted; nil when `refused`.
        var request: JSONValue?
        /// The worker that asked (the agent, for its builds); nil for the app.
        var callerRole: WorkerRole?
        var callerInstance: String?
        var resumes: Int
        /// Why the task cannot be resumed.
        var refused: String?
    }

    /// Sends the request to the task's worker under its task ID, marked resumed.
    typealias Dispatch = @Sendable (_ record: TaskRegistry.Record, _ request: WireRequest) async throws -> WireReply
    /// The host's own checks of the request for its original caller (the
    /// agent's Confirm mode); nil lets it through.
    typealias Recheck = @Sendable (_ caller: Caller, _ request: WireRequest) async -> ApelinError?

    let registry: TaskRegistry
    let dispatch: Dispatch
    let recheck: Recheck

    /// The resume record for a task being started.
    static func plan(_ request: WireRequest, descriptorCount: Int, caller: Caller) -> JSONValue? {
        var plan = Plan(operation: request.operation, request: nil, resumes: 0)
        if case let .worker(role, instance) = caller {
            plan.callerRole = role
            plan.callerInstance = instance
        }
        if case .worker(.agent, _) = caller {
            plan.refused = "The agent session has ended."
        } else if request.operation == .toolchainRemove {
            plan.refused = "Package removal resumes separately. Wait for it to finish before trying again."
        } else if request.operation == .transferImport {
            plan.refused = "Imports cannot resume automatically. Open the file again; a toolchain already installed from it will be reused."
        } else if !operations.contains(request.operation) {
            plan.refused = "\(request.operation.rawValue) cannot resume automatically. Start the task again."
        } else if descriptorCount > 0 {
            plan.refused = "The task's open file was closed. Start the task again."
        } else if let payload = try? JSONCoding.decode(JSONValue.self, from: request.payload) {
            if carriesCredentials(payload) {
                plan.refused = "The request URL may contain credentials, so it was not saved. Start the task again."
            } else {
                plan.request = payload
            }
        } else {
            plan.refused = "The task request could not be saved. Start the task again."
        }
        return try? JSONValue(encoding: plan)
    }

    /// Picks up a task the previous host left running. False: there is no
    /// plan to follow, and the host marks it `interrupted`.
    func resume(_ record: TaskRegistry.Record) async -> Bool {
        guard let value = record.resume, var plan = try? value.decode(Plan.self) else { return false }
        if record.cancelRequested {
            await registry.finish(record.id, .cancelled, message: "Cancelled before the background service stopped.")
            return true
        }
        if let refused = plan.refused {
            await registry.interrupt(
                record.id,
                message: "The background service stopped. This task could not resume: \(refused)",
            )
            return true
        }
        guard plan.resumes < Self.maximumResumes else {
            await registry.interrupt(
                record.id,
                message: "The background service stopped \(plan.resumes + 1) times. Start the task again.",
            )
            return true
        }
        guard let payload = plan.request, let body = try? JSONCoding.encode(payload) else { return false }
        // Counted before the worker starts, so a host that dies resuming it counts too.
        plan.resumes += 1
        await registry.setResume(record.id, try? JSONValue(encoding: plan))
        await registry.append(record.id, kind: "resumed", payload: .object(["resumes": .number(Double(plan.resumes))]))
        let request = WireRequest(operation: plan.operation, payload: body)
        let caller: Caller = plan.callerRole.map { .worker($0, instance: plan.callerInstance) } ?? .app
        Task { await restart(record, request, caller: caller) }
        return true
    }

    private func restart(_ record: TaskRegistry.Record, _ request: WireRequest, caller: Caller) async {
        if let refusal = await recheck(caller, request) {
            await registry.finish(record.id, .failed, message: refusal.description)
            return
        }
        do {
            let reply = try await dispatch(record, request)
            if case let .failure(error) = reply.result {
                await registry.finish(record.id, .failed, message: error.description)
            }
        } catch {
            let failure = (error as? ApelinError) ?? ApelinError(.unavailable, String(describing: error))
            await registry.finish(record.id, .failed, message: failure.description)
        }
    }

    /// Any string in the request that is a URL with a user or password, or
    /// with a host and a query or fragment, where a token can ride as well
    /// (`?token=…`, a signed download's parameters).
    static func carriesCredentials(_ value: JSONValue) -> Bool {
        switch value {
        case let .string(text):
            guard text.contains(":"), let components = URLComponents(string: text), components.scheme != nil else {
                return false
            }
            if components.user != nil || components.password != nil {
                return true
            }
            return components.host != nil && (components.query != nil || components.fragment != nil)
        case let .array(items):
            return items.contains(where: carriesCredentials)
        case let .object(members):
            return members.values.contains(where: carriesCredentials)
        default:
            return false
        }
    }
}
