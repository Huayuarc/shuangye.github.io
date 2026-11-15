import ApelinCore
import ApelinProtocol
import Foundation

// The note that the session host restarted (Apelind/Session/Agent/AgentHostRun.swift):
// the app's open of a conversation it names, the first in a host's run,
// tells its worker; once a message has reached the conversation no open in
// the same run does; a new conversation, an agent's open and a caller that
// sets the field itself are told nothing.

func agentHostRunChecks() async {
    let session = UUID().uuidString.lowercased()
    let reopen = AgentOpenRequest(projectName: "Tweak", sessionID: session, approvalMode: .confirm)

    // MARK: The first open in a fresh host is told; after a message, none is

    do {
        let run = AgentHostRun()
        let first = await run.forwarded(reopen, sessionID: session, byApp: true)
        check(first.hostRestarted == true, "the app's first open of an existing conversation in a fresh host is told")
        check(first.sessionID == session && first.projectName == "Tweak", "and is otherwise the request as it came")
        // Compact… opens with no message: the next open is still told.
        let beforeAnyMessage = await run.forwarded(reopen, sessionID: session, byApp: true)
        check(beforeAnyMessage.hostRestarted == true, "an open no message followed leaves the note due")
        await run.messageReached(session)
        let again = await run.forwarded(reopen, sessionID: session, byApp: true)
        check(again.hostRestarted == nil, "once a message reached it, an open in the same host is not told")
        let other = UUID().uuidString.lowercased()
        let otherOpen = await run.forwarded(
            AgentOpenRequest(projectName: "Tweak", sessionID: other, approvalMode: .confirm),
            sessionID: other,
            byApp: true,
        )
        check(otherOpen.hostRestarted == true, "another conversation is told on its own first open")
        let freshHost = await AgentHostRun().forwarded(reopen, sessionID: session, byApp: true)
        check(freshHost.hostRestarted == true, "a host started again knows nothing of the last one's")
    }

    // MARK: A new conversation and an agent's open are told nothing

    do {
        let run = AgentHostRun()
        let generated = UUID().uuidString.lowercased()
        let new = await run.forwarded(
            AgentOpenRequest(projectName: "Tweak", approvalMode: .confirm),
            sessionID: generated,
            byApp: true,
        )
        check(new.hostRestarted == nil, "a brand-new conversation is told nothing")
        let child = await run.forwarded(
            AgentOpenRequest(projectName: "Tweak", approvalMode: .confirm, prompt: "Build it"),
            sessionID: generated,
            byApp: false,
        )
        check(child.hostRestarted == nil, "a conversation an agent opens is told nothing")
    }

    // MARK: A caller cannot set the field

    do {
        let run = AgentHostRun()
        let generated = UUID().uuidString.lowercased()
        let forged = AgentOpenRequest(projectName: "Tweak", approvalMode: .confirm, hostRestarted: true)
        let fromApp = await run.forwarded(forged, sessionID: generated, byApp: true)
        check(fromApp.hostRestarted == nil, "the app's own hostRestarted on a new conversation is dropped")
        let fromAgent = await run.forwarded(forged, sessionID: generated, byApp: false)
        check(fromAgent.hostRestarted == nil, "an agent's is dropped")
        var reached = reopen
        reached.hostRestarted = true
        await run.messageReached(session)
        let afterMessage = await run.forwarded(reached, sessionID: session, byApp: true)
        check(afterMessage.hostRestarted == nil, "and so is the app's on a conversation a message reached in this run")
        // Decoded as the host decodes it, the field is still the host's to set.
        let wire = try? JSONCoding.decode(
            AgentOpenRequest.self,
            from: Data(#"{"approvalMode":"confirm","sessionID":"\#(session)","hostRestarted":true}"#.utf8),
        )
        let decoded = await run.forwarded(wire ?? reopen, sessionID: session, byApp: true)
        check(wire?.hostRestarted == true && decoded.hostRestarted == nil, "a request that arrives with the field set loses it")
    }
}
