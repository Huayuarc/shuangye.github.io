import ApelinProtocol
import Foundation

/// The conversations a message has reached in this session host's run, in
/// memory only, so the set is empty whenever the host starts. apelind is on
/// demand and the host its child: a conversation the app continues after a
/// new host started may have last run before a reboot, a jailbreak, an
/// update of Apelin or roothide renaming the bootstrap's root, and every
/// path in its history may name what is gone. Its worker is told so
/// (`AgentOpenRequest.hostRestarted`) and tells the model once, in the next
/// message's `<system-state>`.
///
/// What counts is a message reaching the conversation, not its being
/// opened: Compact… opens one with no message, and a worker that stops
/// before the user's message came is opened again with the note still due.
/// Nor is it the session table, which says what the host opened, not what
/// the model was told.
actor AgentHostRun {
    static let shared = AgentHostRun()

    private var reached: Set<String> = []

    /// `open` as session `sessionID`'s worker gets it, `hostRestarted` the
    /// host's alone whatever the caller sent: set when the app continues a
    /// conversation it names by its ID (one an earlier host may have run;
    /// the worker reads its history back and tells the model only if there
    /// is some) that no message has reached in this run.
    func forwarded(_ open: AgentOpenRequest, sessionID: String, byApp: Bool) -> AgentOpenRequest {
        var open = open
        let continued = byApp && open.sessionID == sessionID
        open.hostRestarted = continued && !reached.contains(sessionID) ? true : nil
        return open
    }

    /// A message reached the session's worker: its open's prompt, or an
    /// `agentPrompt` it took. A worker opened for it again in this run is
    /// not told the host restarted.
    func messageReached(_ sessionID: String) {
        reached.insert(sessionID)
    }
}
