import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

// shell_run as root (Apelind/Session/Agent/AgentApprovals.swift,
// AgentRunCode.swift): Full mode runs it; Strict and Relaxed run it only
// with one approval the app gave, with the owner checked, for exactly that
// root request; an approval of an ordinary request, a session grant, a
// preset or a closed session never does; and what the banner and the run's
// environment say about it.

func rootRunChecks(scratch: URL, scratchPath: String) async {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("root-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("root-approvals"))
    let sessions = AgentSessionTable.shared

    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-root", name: "Root", path: scratchPath),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        await ledger.setMode(mode, session: id)
        return entry
    }
    func setMode(_ mode: ApprovalMode, _ id: String) async {
        await sessions.setMode(mode, session: id)
        await ledger.setMode(mode, session: id)
    }
    let install = ["irisin-cli", "install", "--yes", "mobilesubstrate"]
    let argv: (([String]) -> JSONValue) = { .object(["argv": .object(["_0": .array($0.map { .string($0) })])]) }
    // What apelin-agent writes for a root request (`rootCommand`) or an
    // ordinary one (`command`).
    func ask(
        _ entry: AgentSessionTable.Entry,
        _ approvalID: String,
        _ words: [String],
        root: Bool,
        sessionScope: Bool = false,
        workingDirectory: String = ".",
    ) async {
        let key = root ? RunCodeApproval.rootCommandDetail : "command"
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID),
            "tool": .string("shell_run"),
            "workingDirectory": .string(workingDirectory),
            "allowsSessionScope": .bool(sessionScope),
            "detail": .object([key: argv(words)]),
        ]))
    }
    @discardableResult
    func approve(
        _ entry: AgentSessionTable.Entry,
        _ approvalID: String,
        scope: ApprovalScope? = nil,
        ownerVerified: Bool? = true,
        workerTakesIt: Bool = true,
    ) async -> Bool {
        let request = AgentApproveRequest(
            sessionID: entry.sessionID,
            approvalID: approvalID,
            decision: .approve,
            scope: scope,
            ownerVerified: ownerVerified,
        )
        do {
            return try await AgentApprovals.relay(
                request,
                registry: registry,
                ledger: ledger,
                forward: { workerTakesIt },
                accepted: { $0 },
            )
        } catch {
            return false
        }
    }
    func identity(
        _ entry: AgentSessionTable.Entry,
        _ words: [String],
        _ approval: RunCodeApproval,
        root: Bool = true,
        in directory: String = ".",
    ) async -> AgentRunCode.Identity? {
        let run = AgentRunCodeRequest(
            sessionID: entry.sessionID,
            spec: .argv(words),
            workingDirectory: directory,
            approval: approval,
            asRoot: root ? true : nil,
        )
        let current = await sessions.entry(entry.sessionID) ?? entry
        return try? await AgentApprovals.authorize(
            run,
            entry: current,
            registry: registry,
            ledger: ledger,
            installRoot: "/",
        )
    }
    func kept(_ entry: AgentSessionTable.Entry, _ approvalID: String) async -> Bool {
        await sessions.entry(entry.sessionID)?.approvals[approvalID] == .approve
    }

    // MARK: Strict: nothing runs as root without the approval of that root request

    let strict = await session("root-strict", mode: .confirm)
    for evidence: RunCodeApproval in [.relaxed, .preset("ls"), .session, .user(approvalID: "never-asked")] {
        let ran = await identity(strict, ["ls"], evidence)
        check(ran == nil, "Strict runs nothing as root on \(evidence)")
    }
    await ask(strict, "plain", install, root: false)
    await approve(strict, "plain")
    let plainForRoot = await identity(strict, install, .user(approvalID: "plain"))
    check(plainForRoot == nil, "an approval of the command as mobile is no approval of it as root")
    let plainKept = await kept(strict, "plain")
    check(plainKept, "and is left as the app gave it")

    await ask(strict, "root-1", install, root: true)
    let unverified = await approve(strict, "root-1", ownerVerified: nil)
    check(!unverified, "an approval of a root request without the owner checked is refused")
    let unverifiedKept = await kept(strict, "root-1")
    check(!unverifiedKept, "and records nothing")
    let refusedOwner = await approve(strict, "root-1", ownerVerified: false)
    check(!refusedOwner, "nor with the check said to have failed")
    let denied = AgentApproveRequest(sessionID: strict.sessionID, approvalID: "root-1", decision: .deny)
    let denyPassed = await (try? AgentApprovals.relay(
        denied,
        registry: registry,
        ledger: ledger,
        forward: { true },
        accepted: { $0 },
    )) ?? false
    check(denyPassed, "denying a root request needs no check")

    await ask(strict, "root-2", install, root: true)
    await approve(strict, "root-2")
    let otherCommand = await identity(strict, ["irisin-cli", "remove", "--yes", "mobilesubstrate"], .user(approvalID: "root-2"))
    check(otherCommand == nil, "a root approval runs no other command")
    let otherDirectory = await identity(strict, install, .user(approvalID: "root-2"), in: "Sources")
    check(otherDirectory == nil, "nor in another working directory")
    let asMobile = await identity(strict, install, .user(approvalID: "root-2"), root: false)
    check(asMobile == nil, "nor the same command as mobile")
    let stillKept = await kept(strict, "root-2")
    check(stillKept, "none of those spends it")
    let approved = await identity(strict, install, .user(approvalID: "root-2"))
    check(approved == .root, "the approved root request runs as root")
    let again = await identity(strict, install, .user(approvalID: "root-2"))
    check(again == nil, "once")

    // MARK: Never under a session grant

    await ask(strict, "root-session", install, root: true, sessionScope: true)
    await approve(strict, "root-session", scope: .session)
    let grants = await sessions.entry(strict.sessionID)?.runCodeGrants ?? []
    check(grants.isEmpty, "a root request approved for the session leaves no session grant")
    await ask(strict, "mobile-session", install, root: false, sessionScope: true)
    await approve(strict, "mobile-session", scope: .session)
    let mobileGrant = await identity(strict, install, .session, root: false)
    check(mobileGrant == .mobile(preset: nil), "a session grant runs its command as mobile")
    let rootGrant = await identity(strict, install, .session)
    check(rootGrant == nil, "and never as root")

    // MARK: Taken back when the worker does not accept the relay

    await ask(strict, "root-refused", install, root: true)
    await approve(strict, "root-refused", workerTakesIt: false)
    let refusedRelay = await identity(strict, install, .user(approvalID: "root-refused"))
    check(refusedRelay == nil, "a root approval the worker did not accept runs nothing")

    // MARK: Relaxed asks for root too

    let relaxed = await session("root-relaxed", mode: .relaxed)
    let relaxedPlain = await identity(relaxed, install, .relaxed, root: false)
    check(relaxedPlain == .mobile(preset: nil), "Relaxed runs an ordinary call as mobile")
    let relaxedRoot = await identity(relaxed, install, .relaxed)
    check(relaxedRoot == nil, "but nothing as root without asking")
    await ask(relaxed, "relaxed-root", install, root: true)
    await approve(relaxed, "relaxed-root")
    let relaxedApproved = await identity(relaxed, install, .user(approvalID: "relaxed-root"))
    check(relaxedApproved == .root, "an approved root request runs under Relaxed")

    // MARK: Full runs root without asking, by both records of the mode

    let full = await session("root-full", mode: .full)
    let fullRoot = await identity(full, install, .relaxed)
    check(fullRoot == .root, "Full runs a root request without asking")
    let fullPlain = await identity(full, ["make"], .relaxed, root: false)
    check(fullPlain == .mobile(preset: nil), "and an ordinary one as mobile, as Relaxed does")
    await ledger.setMode(.confirm, session: full.sessionID)
    let ledgerDisagrees = await identity(full, install, .relaxed)
    check(ledgerDisagrees == nil, "the session table alone saying Full is not enough")
    await ledger.forgetSession(full.sessionID)
    let ledgerForgot = await identity(full, install, .relaxed)
    check(ledgerForgot == nil, "nor with the ledger not knowing the session")

    // A mode change mid-session applies to the next call.
    await setMode(.full, full.sessionID)
    let backToFull = await identity(full, install, .relaxed)
    check(backToFull == .root, "Full again runs root")
    await setMode(.confirm, full.sessionID)
    let leftFull = await identity(full, install, .relaxed)
    check(leftFull == nil, "leaving Full stops root without asking at once")
    await setMode(.relaxed, full.sessionID)
    let relaxedNow = await identity(full, install, .relaxed)
    check(relaxedNow == nil, "and so does Relaxed")

    // MARK: Forgotten on close, and nothing for an ended session

    let closing = await session("root-closing", mode: .confirm)
    await ask(closing, "root-close", install, root: true)
    await approve(closing, "root-close")
    await sessions.forgetGrants(closing.sessionID)
    let afterClose = await identity(closing, install, .user(approvalID: "root-close"))
    check(afterClose == nil, "a root approval not spent is forgotten when the session closes")

    let ended = await session("root-ended", mode: .full)
    await registry.finish(ended.task.taskID, .succeeded, message: "closed")
    let endedRoot = await identity(ended, install, .relaxed)
    check(endedRoot == nil, "a session whose task ended runs nothing as root, even in Full")
    let endedPlain = await identity(ended, ["make"], .relaxed, root: false)
    check(endedPlain == .mobile(preset: nil), "the ended-task check is root's alone")

    // MARK: The banner names a root request

    var track = AgentNoticeTrack(sessionID: "0b9d3c1e-6a64-4c2f-9d3e-2f1a7c5b8e11")
    let rootNotice = track.take("approvalRequested", payload: .object([
        "approvalID": .string("r"),
        "tool": .string("shell_run"),
        "reason": .string("Runs as root."),
        "detail": .object([RunCodeApproval.rootCommandDetail: argv(install)]),
    ]), title: "Install", posted: AgentNoticeMarks())
    check(rootNotice?.subtitle == .key("Root Approval Required"), "a root request's banner says so")
    let plainNotice = track.take("approvalRequested", payload: .object([
        "approvalID": .string("p"),
        "tool": .string("shell_run"),
        "detail": .object(["command": argv(install)]),
    ]), title: "Install", posted: AgentNoticeMarks())
    check(plainNotice?.subtitle == .key("Approval Required"), "an ordinary request's banner does not")

    // MARK: What a run as root sees, and that it runs

    let project = ResolvedProject(id: "p-root", name: "Root", path: scratchPath)
    let mobileHome = "/var/mobile"
    let rootEntries = AgentRunCode.environment(
        preset: nil,
        project: project,
        installRoot: "/",
        home: mobileHome,
        asRoot: true,
    )
    check(rootEntries.contains("HOME=\(AgentRunCode.rootHome)"), "a run as root has root's own HOME")
    check(!rootEntries.contains("HOME=\(mobileHome)"), "and not mobile's")
    check(rootEntries.contains("APELIN_PROJECT_ROOT=\(scratchPath)"), "in the same project")
    let mobileEntries = AgentRunCode.environment(preset: nil, project: project, installRoot: "/", home: mobileHome)
    check(mobileEntries.contains("HOME=\(mobileHome)"), "a run as mobile keeps mobile's HOME")

    // On the Mac the host is not root, so `.root` runs as this user: what
    // is checked here is that the root path spawns at all, unchanged in
    // its bounds; that it is uid 0 on a device is Device-Validation's.
    let response = try? await AgentRunCode.run(
        AgentRunCodeRequest(sessionID: "root-run", spec: .argv(["id", "-u"]), timeoutSeconds: 10, approval: .relaxed, asRoot: true),
        as: .root,
        project: project,
        installRoot: "/",
        home: NSHomeDirectory(),
        stopsSeen: AgentRunCode.stopCount(session: "root-run"),
    )
    check(
        response?.exitCode == 0 && response?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == String(geteuid()),
        "a root run runs as the host itself, without dropping to mobile: \(String(describing: response))",
    )

    // MARK: A request that does not ask for root runs as mobile (invariant 1)

    // Absent, nil or false `asRoot` all run as mobile, even in Full, which
    // is where the host would run root without asking if it were asked.
    let mobileOnly = await session("root-mobile", mode: .full)
    for flag: Bool? in [nil, false] {
        let run = AgentRunCodeRequest(sessionID: mobileOnly.sessionID, spec: .argv(["make"]), approval: .relaxed, asRoot: flag)
        let who = try? await AgentApprovals.authorize(run, entry: mobileOnly, registry: registry, ledger: ledger, installRoot: "/")
        check(who == .mobile(preset: nil), "asRoot \(String(describing: flag)) runs as mobile, Full or not")
    }
    // A request decoded from JSON written before `asRoot` existed has no
    // such field, and runs as mobile.
    let older = try? JSONCoding.decode(
        AgentRunCodeRequest.self,
        from: Data(
            #"{"sessionID":"root-mobile","spec":{"argv":{"_0":["make"]}},"workingDirectory":".","timeoutSeconds":120,"approval":{"relaxed":{}}}"#
                .utf8,
        ),
    )
    check(older?.asRoot == nil, "an older request has no asRoot field")
    if let older {
        let who = try? await AgentApprovals.authorize(older, entry: mobileOnly, registry: registry, ledger: ledger, installRoot: "/")
        check(who == .mobile(preset: nil), "and runs as mobile")
    } else {
        check(false, "an older request decodes")
    }
    // In every mode and on every kind of evidence — the user's approval of
    // a root card of this very command included — a request that does not
    // ask for root (asRoot absent) never runs as root, and leaves that
    // approval unspent.
    for mode: ApprovalMode in [.confirm, .relaxed, .full] {
        let entry = await session("root-never-\(mode.rawValue)", mode: mode)
        await ask(entry, "never-root", install, root: true)
        await approve(entry, "never-root")
        for evidence: RunCodeApproval in [.relaxed, .preset("ls"), .session, .user(approvalID: "never-root")] {
            let ran = await identity(entry, install, evidence, root: false)
            check(ran != .root, "\(mode) on \(evidence) without asRoot is never root")
        }
        let unspent = await kept(entry, "never-root")
        check(unspent, "\(mode): the root approval is still the app's to spend")
    }

    // MARK: The directory the card showed is the one that runs (invariant 7)

    // The card names `.`, the run sends an empty directory: the host spells
    // both the project root, so they match.
    let norm = await session("root-norm", mode: .confirm)
    await ask(norm, "norm-dot", install, root: true, workingDirectory: ".")
    await approve(norm, "norm-dot")
    let normEmpty = await identity(norm, install, .user(approvalID: "norm-dot"), in: "")
    check(normEmpty == .root, "a root approval shown for the project root runs a call whose directory is empty")
    await ask(norm, "norm-sources", install, root: true, workingDirectory: "Sources")
    await approve(norm, "norm-sources")
    let normOther = await identity(norm, install, .user(approvalID: "norm-sources"), in: "Build")
    check(normOther == nil, "a root approval for one directory runs nothing in another")
    let normSame = await identity(norm, install, .user(approvalID: "norm-sources"), in: "Sources")
    check(normSame == .root, "and runs it in the directory it named")

    // The exact JSON apelin-agent writes under detail.rootCommand (the same
    // shapes as Packages/ApelinAgent/.../RootRequestWireTests.swift): the host
    // decodes each to the spec it compares with the run, so the command the
    // card shows is the command that runs. The app's approval is recorded
    // straight in the table here; the relay and its owner check are above.
    let wireShapes: [(detail: String, spec: RunCodeSpec)] = [
        (#"{"argv":{"_0":["irisin-cli","install","--yes","x"]}}"#, .argv(["irisin-cli", "install", "--yes", "x"])),
        (
            #"{"shell":{"_0":"irisin-cli install --yes x | tee log"}}"#,
            .script(interpreter: "sh", source: "irisin-cli install --yes x | tee log"),
        ),
        (#"{"script":{"interpreter":"python3","source":"print(1)"}}"#, .script(interpreter: "python3", source: "print(1)")),
    ]
    let wire = await session("root-wire", mode: .confirm)
    for (index, shape) in wireShapes.enumerated() {
        let id = "wire-\(index)"
        let detail = (try? JSONCoding.decode(JSONValue.self, from: Data(shape.detail.utf8))) ?? .null
        await registry.append(wire.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(id),
            "tool": .string("shell_run"),
            "workingDirectory": .string("."),
            "detail": .object([RunCodeApproval.rootCommandDetail: detail]),
        ]))
        await sessions.record(wire.sessionID, approvalID: id, decision: .approve)
        let run = AgentRunCodeRequest(sessionID: wire.sessionID, spec: shape.spec, approval: .user(approvalID: id), asRoot: true)
        let current = await sessions.entry(wire.sessionID) ?? wire
        let who = try? await AgentApprovals.authorize(run, entry: current, registry: registry, ledger: ledger, installRoot: "/")
        check(who == .root, "a root card written as the worker writes it authorises its own spec (\(shape.detail))")
    }

    // MARK: Forgotten on a session reopen and a host restart (invariant 4)

    let reopened = await session("root-reopen", mode: .confirm)
    await ask(reopened, "reopen-root", install, root: true)
    await approve(reopened, "reopen-root")
    // Reopening the session (AgentHandler.open) replaces its table entry
    // with a fresh one, so the unspent approval is gone.
    await sessions.add(AgentSessionTable.Entry(
        sessionID: reopened.sessionID,
        task: reopened.task,
        project: reopened.project,
        mode: .confirm,
        createdAt: Date(),
    ))
    let afterReopen = await identity(reopened, install, .user(approvalID: "reopen-root"))
    check(afterReopen == nil, "a root approval does not survive a session reopen")

    // A host restart keeps no session's mode (the ledger's modes are in
    // memory): a fresh ledger holds a session it never learned to Strict, so
    // Full does not survive it.
    let restarted = await session("root-restart", mode: .full)
    let freshLedger = ApprovalLedger(directory: scratch.appendingPathComponent("root-approvals-fresh"))
    let afterRestart = try? await AgentApprovals.authorize(
        AgentRunCodeRequest(sessionID: restarted.sessionID, spec: .argv(install), approval: .relaxed, asRoot: true),
        entry: restarted,
        registry: registry,
        ledger: freshLedger,
        installRoot: "/",
    )
    check(afterRestart == nil, "Full does not survive a host restart")
    let freshMode = await freshLedger.mode(session: restarted.sessionID)
    check(freshMode == .confirm, "and a session the ledger never learned is Strict")

    // MARK: Only the app puts a session into Full (invariant 5)

    // An agent's open takes the opener's mode, never the request's: a Strict
    // session cannot open a Full child, and a Full child is Full only
    // because the app made the opener Full.
    let other = ResolvedProject(id: "p-other", name: "Other", path: scratchPath)
    let homeProject = ResolvedProject(id: "p-home", name: "Home", path: scratchPath)
    let strictOpener = await AgentSessionTable.Entry(
        sessionID: "opener-strict",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "opener-strict"),
        project: homeProject,
        mode: .confirm,
        createdAt: Date(),
    )
    let wantsFull = AgentOpenRequest(approvalMode: .full, prompt: "install the dependency")
    let strictChild = try? AgentConversationRules.childOpen(wantsFull, opener: strictOpener, target: other)
    check(strictChild?.approvalMode == .confirm, "an agent's open takes the opener's mode, never the request's Full")
    let fullOpener = await AgentSessionTable.Entry(
        sessionID: "opener-full",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "opener-full"),
        project: homeProject,
        mode: .full,
        createdAt: Date(),
    )
    let fullChild = try? AgentConversationRules.childOpen(
        AgentOpenRequest(approvalMode: .confirm, prompt: "x"),
        opener: fullOpener,
        target: other,
    )
    check(fullChild?.approvalMode == .full, "a Full opener's child is Full, from the opener alone")

    // An agent's prompt carries no approval mode: it cannot switch a session
    // to Full, whatever it sent on the wire.
    let targetEntry = await AgentSessionTable.Entry(
        sessionID: "target-sess",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "target-sess"),
        project: other,
        mode: .confirm,
        createdAt: Date(),
    )
    let childMessage = try? AgentConversationRules.childPrompt(
        AgentPromptRequest(sessionID: targetEntry.sessionID, text: "run as root", approvalMode: .full),
        sender: strictOpener,
        target: targetEntry,
        descriptorCount: 0,
    )
    check(childMessage != nil, "an agent's message to another conversation is built")
    check(childMessage?.approvalMode == nil, "an agent's prompt carries no approval mode, so it cannot imply Full")

    // MARK: A root run keeps a mobile run's bounds (invariant 8)

    let bounds = ResolvedProject(id: "p-root", name: "Root", path: scratchPath)
    // The environment differs from a mobile run's by HOME alone: the host
    // builds it, so a root run inherits nothing more of the worker's.
    let rootEnvironment = AgentRunCode.environment(preset: nil, project: bounds, installRoot: "/", home: "/var/mobile", asRoot: true)
    let mobileEnvironment = AgentRunCode.environment(preset: nil, project: bounds, installRoot: "/", home: "/var/mobile")
    check(
        Set(rootEnvironment).subtracting(mobileEnvironment) == ["HOME=\(AgentRunCode.rootHome)"]
            && Set(mobileEnvironment).subtracting(rootEnvironment) == ["HOME=/var/mobile"],
        "a root run's environment differs from a mobile run's by HOME alone: \(Set(rootEnvironment).symmetricDifference(mobileEnvironment))",
    )

    // The timeout bounds a root run: a one-second cap kills a longer sleep,
    // the same as a mobile run.
    let timed = try? await AgentRunCode.run(
        AgentRunCodeRequest(sessionID: "root-timeout", spec: .argv(["sleep", "5"]), timeoutSeconds: 1, approval: .relaxed, asRoot: true),
        as: .root,
        project: bounds,
        installRoot: "/",
        home: NSHomeDirectory(),
        stopsSeen: AgentRunCode.stopCount(session: "root-timeout"),
    )
    check(timed?.timedOut == true && timed?.exitCode == -1, "the timeout kills a root run that overruns: \(String(describing: timed))")

    // The working directory must resolve inside the project, root or not.
    let escaped = try? await AgentRunCode.run(
        AgentRunCodeRequest(sessionID: "root-escape", spec: .argv(["id"]), workingDirectory: "../..", approval: .relaxed, asRoot: true),
        as: .root,
        project: bounds,
        installRoot: "/",
        home: NSHomeDirectory(),
        stopsSeen: 0,
    )
    check(escaped == nil, "a root run cannot leave the project")

    // And the timeout is bounded, as for a mobile run.
    let ranged = try? await AgentRunCode.run(
        AgentRunCodeRequest(sessionID: "root-range", spec: .argv(["id"]), timeoutSeconds: 99999, approval: .relaxed, asRoot: true),
        as: .root,
        project: bounds,
        installRoot: "/",
        home: NSHomeDirectory(),
        stopsSeen: 0,
    )
    check(ranged == nil, "a root run's timeout is bounded")

    // Its output is capped as a mobile run's is: past 256 KiB it is cut and
    // marked truncated.
    let loud = try? await AgentRunCode.run(
        AgentRunCodeRequest(
            sessionID: "root-loud",
            spec: .script(interpreter: "sh", source: "yes x | head -c 400000"),
            timeoutSeconds: 10,
            approval: .relaxed,
            asRoot: true,
        ),
        as: .root,
        project: bounds,
        installRoot: "/",
        home: NSHomeDirectory(),
        stopsSeen: 0,
    )
    check(
        loud?.truncated == true && loud?.stdout.utf8.count == 256 * 1024,
        "a root run's output is capped: \(loud?.stdout.utf8.count ?? -1) bytes, truncated \(String(describing: loud?.truncated))",
    )
}
