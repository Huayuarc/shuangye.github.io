import ApelinCore
import ApelinProtocol
import Foundation

// Ask Before Using the Screen (ApelinProtocol's ScreenConsent,
// Apelind/Session/Agent/AgentScreenRules.swift, AgentApprovals.authorize):
// while a session asks, an agent's readUITree, uiAction and every
// agentRunCode that runs icli need one approval the app gave that session
// for exactly that call, in Strict, Relaxed and Full alike; with the
// setting off they pass as before; an agent's open takes its opener's
// setting and an agent's message changes none; absent on the wire is on.

func screenConsentChecks(scratch: URL, scratchPath: String) async {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("screen-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("screen-approvals"))
    let sessions = AgentSessionTable.shared
    let project = ResolvedProject(id: "p-screen", name: "Screen", path: scratchPath)

    // MARK: The setting on the wire, and what runs icli

    check(ScreenConsent.asks(nil) && ScreenConsent.asks(true) && !ScreenConsent.asks(false), "absent is on; only false turns it off")
    let oldOpen = try? JSONCoding.decode(AgentOpenRequest.self, from: Data(#"{"approvalMode":"relaxed"}"#.utf8))
    check(oldOpen != nil && oldOpen?.asksBeforeScreen == nil, "an open request from before the setting decodes without it")
    check(ScreenConsent.asks(oldOpen?.asksBeforeScreen), "and asks")
    let oldPrompt = try? JSONCoding.decode(AgentPromptRequest.self, from: Data(#"{"sessionID":"s","text":"hi"}"#.utf8))
    check(oldPrompt != nil && oldPrompt?.asksBeforeScreen == nil, "a prompt without it leaves the session's as it is")

    let screenSpecs: [RunCodeSpec] = [
        .argv(["icli", "url", "open", "https://github.com/Lakr233/Irisin/issues/new"]),
        .argv(["/var/jb/usr/bin/icli", "screen", "info"]),
        .argv(["ICLI", "--help"]),
        .argv(["env", "icli", "app", "list"]),
        .argv(["sh", "-c", "icli app launch com.apple.Preferences"]),
        .argv(["uiopen", "https://example.com"]),
        .argv(["uishoot"]),
        .script(interpreter: "sh", source: "x=$(icli screen info); echo \"$x\""),
        .script(interpreter: "python3", source: "import subprocess\nsubprocess.run([\"icli\", \"input\", \"type\", \"hi\"])"),
    ]
    for spec in screenSpecs {
        check(ScreenConsent.usesScreen(spec), "\(spec) runs a screen program")
    }
    let otherSpecs: [RunCodeSpec] = [
        .argv(["ls", "-la"]),
        .argv(["make", "all"]),
        .argv(["musicli"]),
        .argv(["cat", "Sources/iclient.c"]),
        .script(interpreter: "sh", source: "echo publicli"),
    ]
    for spec in otherSpecs {
        check(!ScreenConsent.usesScreen(spec), "\(spec) runs no screen program")
    }

    // MARK: Sessions, cards and approvals as the worker and the app make them

    func session(_ id: String, mode: ApprovalMode, asks: Bool = true) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: project,
            mode: mode,
            asksBeforeScreen: asks,
            createdAt: Date(),
        )
        await sessions.add(entry)
        await ledger.setMode(mode, session: id)
        return entry
    }
    func json(_ text: String) -> JSONValue {
        (try? JSONCoding.decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }
    // apelin-agent's `detail` for each screen card, as ScreenRequestWireTests
    // pins it.
    let treeDetail = json(#"{"screenControl":{"operation":"readUITree","request":{}}}"#)
    let settingsTreeDetail = json(#"{"screenControl":{"operation":"readUITree","request":{"targetID":"com.apple.Preferences"}}}"#)
    let tapDetail = json(#"{"screenControl":{"operation":"uiAction","request":{"action":{"tap":{"x":10,"y":20.5}}}}}"#)
    let openURL = ["icli", "url", "open", "https://example.com"]
    let openDetail = json(#"{"command":{"argv":{"_0":["icli","url","open","https://example.com"]}},"screenControl":{"operation":"agentRunCode"}}"#)
    let rootDetail = json(#"{"rootCommand":{"argv":{"_0":["icli","url","open","https://example.com"]}},"screenControl":{"operation":"agentRunCode"}}"#)
    let plainDetail = json(#"{"command":{"argv":{"_0":["icli","url","open","https://example.com"]}}}"#)
    let shellDetail = json(#"{"command":{"shell":{"_0":"icli screen info | head"}},"screenControl":{"operation":"agentRunCode"}}"#)

    func ask(_ entry: AgentSessionTable.Entry, _ approvalID: String, tool: AgentToolName, detail: JSONValue) async {
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID),
            "tool": .string(tool.rawValue),
            "workingDirectory": .string("."),
            "allowsSessionScope": .bool(false),
            "detail": detail,
        ]))
    }
    @discardableResult
    func approve(_ entry: AgentSessionTable.Entry, _ approvalID: String, ownerVerified: Bool? = nil) async -> Bool {
        let request = AgentApproveRequest(
            sessionID: entry.sessionID,
            approvalID: approvalID,
            decision: .approve,
            ownerVerified: ownerVerified,
        )
        return await (try? AgentApprovals.relay(
            request,
            registry: registry,
            ledger: ledger,
            forward: { true },
            accepted: { $0 },
        )) ?? false
    }
    func kept(_ entry: AgentSessionTable.Entry, _ approvalID: String) async -> Bool {
        await sessions.entry(entry.sessionID)?.approvals[approvalID] == .approve
    }
    // Whether the host lets an agent's request through; `caller` stands in
    // for the worker that sends it.
    func passes(_ request: some OperationRequest, from entry: AgentSessionTable.Entry, caller: Caller? = nil) async -> Bool {
        guard let wire = try? WireRequest(request) else { return false }
        let refusal = await AgentScreenRules.authorize(
            wire,
            caller: caller ?? .worker(.agent, instance: entry.sessionID),
            registry: registry,
        )
        return refusal == nil
    }
    func identity(
        _ entry: AgentSessionTable.Entry,
        _ spec: RunCodeSpec,
        _ approval: RunCodeApproval,
        root: Bool = false,
        in directory: String = ".",
    ) async -> AgentRunCode.Identity? {
        let run = AgentRunCodeRequest(
            sessionID: entry.sessionID,
            spec: spec,
            workingDirectory: directory,
            approval: approval,
            asRoot: root ? true : nil,
        )
        let current = await sessions.entry(entry.sessionID) ?? entry
        return try? await AgentApprovals.authorize(run, entry: current, registry: registry, ledger: ledger, installRoot: "/")
    }

    // MARK: The UI tree and actions, in every mode

    let tree = ReadUITreeRequest()
    let tap = UIActionRequest(action: .tap(x: 10, y: 20.5))
    for mode in [ApprovalMode.confirm, .relaxed, .full] {
        let entry = await session("screen-\(mode.rawValue)", mode: mode)
        let unasked = await passes(tree, from: entry)
        check(!unasked, "\(mode): an agent reads the UI tree only with the user's approval")
        let unaskedTap = await passes(tap, from: entry)
        check(!unaskedTap, "\(mode): and acts on the screen only with it")

        await ask(entry, "tree", tool: .screenReadTree, detail: treeDetail)
        await approve(entry, "tree")
        let otherTarget = await passes(ReadUITreeRequest(targetID: "com.apple.Preferences"), from: entry)
        check(!otherTarget, "\(mode): an approval of the front app's tree reads no named app's")
        let treeForTap = await passes(tap, from: entry)
        check(!treeForTap, "\(mode): nor acts on the screen")
        let treeKept = await kept(entry, "tree")
        check(treeKept, "\(mode): neither spends it")
        let read = await passes(tree, from: entry)
        check(read, "\(mode): the approved read goes through")
        let readAgain = await passes(tree, from: entry)
        check(!readAgain, "\(mode): once")

        await ask(entry, "settings-tree", tool: .screenReadTree, detail: settingsTreeDetail)
        await approve(entry, "settings-tree")
        let namedRead = await passes(ReadUITreeRequest(targetID: "com.apple.Preferences"), from: entry)
        check(namedRead, "\(mode): a read of a named app goes through on the approval naming it")

        await ask(entry, "tap", tool: .screenInteract, detail: tapDetail)
        await approve(entry, "tap")
        let elsewhere = await passes(UIActionRequest(action: .tap(x: 10, y: 21)), from: entry)
        check(!elsewhere, "\(mode): an approved tap is no tap elsewhere")
        let inAnApp = await passes(UIActionRequest(targetID: "com.apple.mobilesafari", action: .tap(x: 10, y: 20.5)), from: entry)
        check(!inAnApp, "\(mode): nor the same tap in a named app")
        let typed = await passes(UIActionRequest(action: .type(text: "hi")), from: entry)
        check(!typed, "\(mode): nor another action")
        let tapped = await passes(tap, from: entry)
        check(tapped, "\(mode): the approved tap goes through")
        let tappedAgain = await passes(tap, from: entry)
        check(!tappedAgain, "\(mode): once")
        // the host adds Apelin to an agent's action; that is not part of it
        await ask(entry, "tap-2", tool: .screenInteract, detail: tapDetail)
        await approve(entry, "tap-2")
        let scoped = await passes(UIActionRequest(action: .tap(x: 10, y: 20.5), refusedBundleIDs: ["x"]), from: entry)
        check(scoped, "\(mode): what the agent sends as refusedBundleIDs does not change what was approved")
    }

    // An approval shown for one tool approves nothing else.
    let mixed = await session("screen-mixed", mode: .relaxed)
    await ask(mixed, "wrong-tool", tool: .screenInteract, detail: treeDetail)
    await approve(mixed, "wrong-tool")
    let wrongTool = await passes(tree, from: mixed)
    check(!wrongTool, "a tree read's detail on another tool's card approves no read")
    await ask(mixed, "no-marker", tool: .screenReadTree, detail: .object([:]))
    await approve(mixed, "no-marker")
    let noMarker = await passes(tree, from: mixed)
    check(!noMarker, "nor does a card that did not say it uses the screen")

    // The app's and the console's calls, a session that does not ask, and a
    // worker with no session.
    let byApp = await passes(tree, from: mixed, caller: .app)
    check(byApp, "the app's own read is untouched")
    let unasking = await session("screen-off", mode: .relaxed, asks: false)
    let offRead = await passes(tree, from: unasking)
    let offTap = await passes(tap, from: unasking)
    check(offRead && offTap, "with the setting off the screen tools pass as before")
    let noSession = await passes(tree, from: unasking, caller: .worker(.agent, instance: "no-such-session"))
    check(!noSession, "a worker that serves no session reads nothing")

    // A prompt from the app changes it from the next call on.
    await sessions.setAsksBeforeScreen(true, session: unasking.sessionID)
    let backOn = await passes(tree, from: unasking)
    check(!backOn, "turned on again, the next read needs an approval")
    await sessions.setAsksBeforeScreen(false, session: unasking.sessionID)
    let backOff = await passes(tree, from: unasking)
    check(backOff, "and turned off, it does not")

    // MARK: shell_run that runs icli, in every mode

    let open: RunCodeSpec = .argv(openURL)
    for mode in [ApprovalMode.confirm, .relaxed, .full] {
        let entry = await session("icli-\(mode.rawValue)", mode: mode)
        for evidence: RunCodeApproval in [.relaxed, .preset("ls"), .session, .user(approvalID: "never-asked")] {
            let ran = await identity(entry, open, evidence)
            check(ran == nil, "\(mode): icli runs on no \(evidence)")
        }
        await ask(entry, "plain", tool: .shellRun, detail: plainDetail)
        await approve(entry, "plain")
        let plain = await identity(entry, open, .user(approvalID: "plain"))
        check(plain == nil, "\(mode): an approval of the command on a card that did not say it uses the screen runs no icli")
        let plainKept = await kept(entry, "plain")
        check(plainKept, "\(mode): and is left as the app gave it")

        await ask(entry, "open", tool: .shellRun, detail: openDetail)
        await approve(entry, "open")
        let otherCommand = await identity(entry, .argv(["icli", "url", "open", "https://example.org"]), .user(approvalID: "open"))
        check(otherCommand == nil, "\(mode): an approved icli command runs no other")
        let otherDirectory = await identity(entry, open, .user(approvalID: "open"), in: "Sources")
        check(otherDirectory == nil, "\(mode): nor in another working directory")
        let asRoot = await identity(entry, open, .user(approvalID: "open"), root: true)
        check(asRoot == nil, "\(mode): nor as root")
        let openKept = await kept(entry, "open")
        check(openKept, "\(mode): none of those spends it")
        let opened = await identity(entry, open, .user(approvalID: "open"))
        check(opened == .mobile(preset: nil), "\(mode): the approved command runs as mobile")
        let openedAgain = await identity(entry, open, .user(approvalID: "open"))
        check(openedAgain == nil, "\(mode): once")

        await ask(entry, "shell", tool: .shellRun, detail: shellDetail)
        await approve(entry, "shell")
        let shell = await identity(entry, .script(interpreter: "sh", source: "icli screen info | head"), .user(approvalID: "shell"))
        check(shell == .mobile(preset: nil), "\(mode): shell text that runs icli goes as the sh script it is sent as")

        let make = await identity(entry, .argv(["make"]), mode.asks ? .user(approvalID: "never-asked") : .relaxed)
        check((make == nil) == mode.asks, "\(mode): a command that runs no screen program is decided as before")
    }

    // As root: only on a root card that said it uses the screen, with the
    // owner checked, in Full too.
    let full = await session("icli-root", mode: .full)
    let fullRoot = await identity(full, open, .relaxed, root: true)
    check(fullRoot == nil, "Full runs no icli as root without asking while the setting is on")
    await ask(full, "root", tool: .shellRun, detail: rootDetail)
    let unverified = await approve(full, "root")
    check(!unverified, "a root screen card is approved only with the owner checked")
    await approve(full, "root", ownerVerified: true)
    let rootAsMobile = await identity(full, open, .user(approvalID: "root"))
    check(rootAsMobile == nil, "a root card's approval runs the command as root only")
    let rootRun = await identity(full, open, .user(approvalID: "root"), root: true)
    check(rootRun == .root, "and runs it as root")

    // Off: as before, by the mode.
    let relaxedOff = await session("icli-off", mode: .relaxed, asks: false)
    let offRun = await identity(relaxedOff, open, .relaxed)
    check(offRun == .mobile(preset: nil), "with the setting off, Relaxed runs icli as before")
    let strictOff = await session("icli-strict-off", mode: .confirm, asks: false)
    await ask(strictOff, "plain", tool: .shellRun, detail: plainDetail)
    await approve(strictOff, "plain")
    let strictOffRun = await identity(strictOff, open, .user(approvalID: "plain"))
    check(strictOffRun == .mobile(preset: nil), "and Strict on the command's ordinary approval")

    // Closed: what is left goes.
    let closing = await session("icli-close", mode: .relaxed)
    await ask(closing, "open", tool: .shellRun, detail: openDetail)
    await approve(closing, "open")
    await sessions.forgetGrants(closing.sessionID)
    let afterClose = await identity(closing, open, .user(approvalID: "open"))
    check(afterClose == nil, "a closed session's unspent screen approval runs nothing")

    // MARK: Conversations agents open and send to

    let opener = await session("screen-opener", mode: .relaxed)
    let child = try? AgentConversationRules.childOpen(
        AgentOpenRequest(approvalMode: .relaxed, asksBeforeScreen: false, prompt: "go"),
        opener: opener,
        target: project,
    )
    check(child?.asksBeforeScreen == true, "an agent's open takes its opener's setting, never the one it sent")
    let lax = await session("screen-lax-opener", mode: .relaxed, asks: false)
    let laxChild = try? AgentConversationRules.childOpen(
        AgentOpenRequest(approvalMode: .relaxed, asksBeforeScreen: true, prompt: "go"),
        opener: lax,
        target: project,
    )
    check(laxChild?.asksBeforeScreen == false, "an opener that does not ask opens one that does not")
    let target = await session("screen-target", mode: .relaxed)
    let sent = try? AgentConversationRules.childPrompt(
        AgentPromptRequest(sessionID: target.sessionID, text: "go", asksBeforeScreen: false),
        sender: opener,
        target: target,
        descriptorCount: 0,
    )
    check(sent != nil && sent?.asksBeforeScreen == nil, "an agent's message changes no conversation's setting")
    let fromApp = AgentConversationRules.appPrompt(AgentPromptRequest(sessionID: target.sessionID, text: "go", asksBeforeScreen: false))
    check(fromApp.asksBeforeScreen == false, "the app's prompt carries its setting")
}
