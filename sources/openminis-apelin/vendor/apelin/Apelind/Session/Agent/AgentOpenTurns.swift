import Foundation

/// One `agentOpen` of a session at a time. An open takes its session's turn
/// before it makes a single check and gives it back once it has answered,
/// so an open of a session that is already being opened — the app asking
/// again while a long conversation's worker is still reading its log —
/// waits for that one to answer, then makes every check of its own and
/// finds the task it registered, rather than registering a second task and
/// handing the same worker a second open. A turn is one session's: an open
/// of another session never waits for it, and the opens waiting take it in
/// the order they came.
///
/// A waiter whose own task is cancelled leaves the line and opens nothing;
/// the open under way and the others waiting go on as they were. One handed
/// its turn before the cancel came opens as any other does.
actor AgentOpenTurns {
    static let shared = AgentOpenTurns()

    private struct Waiter {
        var token: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    /// The sessions with an open under way, each with the opens waiting for
    /// it, oldest first.
    private var lines: [String: [Waiter]] = [:]

    /// Runs `open` in the session's turn, and gives the turn to the next
    /// open however this one ends, a failure included. Nil, with `open` never
    /// run, when the caller's task was cancelled while it waited.
    nonisolated func run<T>(for sessionID: String, _ open: () async throws -> T) async rethrows -> T? {
        guard await begin(sessionID) else { return nil }
        do {
            let result = try await open()
            await end(sessionID)
            return result
        } catch {
            await end(sessionID)
            throw error
        }
    }

    /// How many opens of the session are waiting for its turn.
    func waiting(_ sessionID: String) -> Int {
        lines[sessionID]?.count ?? 0
    }

    /// Waits for the session's turn and takes it; false, holding nothing,
    /// when the caller's task was cancelled while it waited.
    private func begin(_ sessionID: String) async -> Bool {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if lines[sessionID] == nil {
                    lines[sessionID] = []
                    continuation.resume(returning: true)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    lines[sessionID]?.append(Waiter(token: token, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.leave(sessionID, token) }
        }
    }

    /// Hands the session's turn to the open that has waited longest, or
    /// frees it when none is waiting.
    private func end(_ sessionID: String) {
        guard var line = lines[sessionID] else { return }
        guard !line.isEmpty else {
            lines[sessionID] = nil
            return
        }
        let next = line.removeFirst()
        lines[sessionID] = line
        next.continuation.resume(returning: true)
    }

    /// A waiter's task was cancelled: it leaves the line, unless it has
    /// been handed the turn already.
    private func leave(_ sessionID: String, _ token: UUID) {
        guard let index = lines[sessionID]?.firstIndex(where: { $0.token == token }) else { return }
        lines[sessionID]?.remove(at: index).continuation.resume(returning: false)
    }
}
