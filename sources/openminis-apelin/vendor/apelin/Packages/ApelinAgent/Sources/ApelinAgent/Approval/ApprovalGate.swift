import Foundation
import KWWKAI

public enum ApprovalError: Error, Equatable, LocalizedError {
    case unknownRequest
    public var errorDescription: String? {
        switch self {
        case .unknownRequest: "This approval request is no longer waiting for a decision."
        }
    }
}

/// Holds the calls waiting for a decision. A waiting call resumes only on
/// `resolve` or cancellation (abort): an app that is not connected leaves it
/// waiting, and nothing approves by default.
actor ApprovalGate {
    private var waiting: [String: (
        request: ApprovalRequest,
        continuation: CheckedContinuation<ApprovalDecision, Never>,
    )] = [:]
    private var sessionFingerprints: Set<String> = []
    private let emit: @Sendable (AgentSessionEvent) async -> Void

    init(emit: @escaping @Sendable (AgentSessionEvent) async -> Void) {
        self.emit = emit
    }

    var pending: [ApprovalRequest] {
        waiting.values.map(\.request).sorted { $0.id < $1.id }
    }

    func isRemembered(_ fingerprint: String) -> Bool {
        sessionFingerprints.contains(fingerprint)
    }

    /// Emits `approvalRequested` and suspends until a decision arrives.
    func request(_ request: ApprovalRequest, cancellation: CancellationHandle?) async -> ApprovalDecision {
        await emit(.approvalRequested(request))
        let id = request.id
        let registration = cancellation?.onCancel { reason in
            Task { await self.cancel(id, reason: reason ?? "aborted") }
        }
        defer { registration?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancellation?.isCancelled == true || Task.isCancelled {
                    continuation.resume(returning: .deny(reason: "aborted"))
                    Task { await self.emit(.approvalResolved(requestID: id, decision: .deny(reason: "aborted"))) }
                    return
                }
                waiting[id] = (request, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id, reason: "aborted") }
        }
    }

    func resolve(_ id: String, decision: ApprovalDecision) async throws {
        guard let entry = waiting.removeValue(forKey: id) else { throw ApprovalError.unknownRequest }
        if case .approve(.session) = decision, entry.request.allowsSessionScope {
            sessionFingerprints.insert(entry.request.fingerprint)
        }
        await emit(.approvalResolved(requestID: id, decision: decision))
        entry.continuation.resume(returning: decision)
    }

    func cancel(_ id: String, reason: String) async {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        let decision = ApprovalDecision.deny(reason: reason)
        await emit(.approvalResolved(requestID: id, decision: decision))
        entry.continuation.resume(returning: decision)
    }

    func cancelAll(reason: String) async {
        for id in waiting.keys.sorted() {
            await cancel(id, reason: reason)
        }
    }
}
