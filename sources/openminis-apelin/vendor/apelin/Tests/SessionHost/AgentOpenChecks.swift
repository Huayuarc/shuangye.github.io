import Foundation

// One agentOpen of a session at a time (Apelind/Session/Agent/AgentOpenTurns.swift):
// an open of a session that is being opened waits for that one to answer,
// then finds the session it registered; another session's open never
// waits; the waiting go in the order they came; a failed open frees the
// session; a waiter whose task is cancelled leaves the line alone.

/// What the opens did, in the order they did it.
private actor Log {
    private(set) var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }
}

/// Holds an open back until the check lets it answer, as a worker that is
/// slow to open a session does.
private actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// The session table in miniature: what AgentHandler.open looks up before
/// its worker opens the session and adds after, and how often each
/// happened.
private actor Sessions {
    private var registered: Set<String> = []
    private(set) var registrations = 0
    private(set) var foundRegistered = 0

    func lookUp(_ sessionID: String) -> Bool {
        let found = registered.contains(sessionID)
        if found {
            foundRegistered += 1
        }
        return found
    }

    func register(_ sessionID: String) {
        registered.insert(sessionID)
        registrations += 1
    }
}

private struct OpenFailed: Error {}

/// Polls until `condition` holds, for at most five seconds: a check that
/// would wait forever fails instead.
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0 ..< 5000 {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

func agentOpenChecks() async {
    // MARK: A second open waits for the first; another session does not

    do {
        let turns = AgentOpenTurns()
        let session = UUID().uuidString
        let other = UUID().uuidString
        let log = Log()
        let worker = Latch()
        let first = Task {
            await turns.run(for: session) {
                await log.append("first began")
                await worker.wait()
                await log.append("first answered")
            }
        }
        let firstBegan = await eventually { await log.lines == ["first began"] }
        check(firstBegan, "the first open of a session starts at once")
        let second = Task {
            await turns.run(for: session) { await log.append("second began") }
        }
        let secondWaits = await eventually { await turns.waiting(session) == 1 }
        check(secondWaits, "a second open of the same session waits")
        let elsewhere = Task {
            await turns.run(for: other) { await log.append("other session opened") }
        }
        let otherOpened = await eventually { await log.lines.contains("other session opened") }
        check(otherOpened, "an open of another session is not held up by it")
        await elsewhere.value
        let meanwhile = await log.lines
        check(
            meanwhile == ["first began", "other session opened"],
            "the second has not begun while the first is under way: \(meanwhile)",
        )
        await worker.open()
        await first.value
        await second.value
        let lines = await log.lines
        check(
            lines == ["first began", "other session opened", "first answered", "second began"],
            "the second open begins only once the first has answered: \(lines)",
        )
        let again = await turns.run(for: session) { "opened" }
        let left = await turns.waiting(session)
        check(again == "opened" && left == 0, "and then the session is free again")
    }

    // MARK: A failed open frees the session for the next

    do {
        let turns = AgentOpenTurns()
        let session = UUID().uuidString
        let log = Log()
        let worker = Latch()
        let failing = Task {
            try await turns.run(for: session) {
                await log.append("failing began")
                await worker.wait()
                throw OpenFailed()
            }
        }
        let failingBegan = await eventually { await log.lines == ["failing began"] }
        check(failingBegan, "the open that will fail starts")
        let next = Task {
            await turns.run(for: session) {
                await log.append("next began")
                return "opened"
            }
        }
        let nextWaits = await eventually { await turns.waiting(session) == 1 }
        check(nextWaits, "the next open waits for it")
        await worker.open()
        var failed = false
        if case .failure(is OpenFailed) = await failing.result {
            failed = true
        }
        check(failed, "the failure reaches the open that failed")
        let opened = await next.value
        check(opened == "opened", "and the next open runs once it has failed")
        let lines = await log.lines
        check(lines == ["failing began", "next began"], "in that order: \(lines)")
    }

    // MARK: The waiting take the turn in the order they came

    do {
        let turns = AgentOpenTurns()
        let session = UUID().uuidString
        let log = Log()
        let worker = Latch()
        let holder = Task {
            await turns.run(for: session) {
                await log.append("holder")
                await worker.wait()
            }
        }
        let held = await eventually { await log.lines == ["holder"] }
        check(held, "the turn is held")
        var waiters: [Task<Void?, Never>] = []
        for index in 1 ... 5 {
            waiters.append(Task { await turns.run(for: session) { await log.append("open \(index)") } })
            let joined = await eventually { await turns.waiting(session) == index }
            check(joined, "open \(index) joins the line")
        }
        await worker.open()
        await holder.value
        for waiter in waiters {
            await waiter.value
        }
        let lines = await log.lines
        check(
            lines == ["holder"] + (1 ... 5).map { "open \($0)" },
            "the waiting opens run one after another, in the order they came: \(lines)",
        )
    }

    // MARK: Twenty opens of one session at once register it once

    do {
        let turns = AgentOpenTurns()
        let session = UUID().uuidString
        let sessions = Sessions()
        let count = 20
        // As AgentHandler.open does: look the session up and, when it is not
        // registered, have its worker open it — an await, a long one for a
        // long conversation, here until every other open has asked — before
        // registering it. Without the turns, every open would look the
        // session up before the first one registered it.
        let opens = (0 ..< count).map { _ in
            Task {
                await turns.run(for: session) {
                    guard await !sessions.lookUp(session) else { return }
                    _ = await eventually { await turns.waiting(session) == count - 1 }
                    await sessions.register(session)
                }
            }
        }
        var answered = 0
        for open in opens {
            if await open.value != nil {
                answered += 1
            }
        }
        check(answered == count, "every open of the session answers: \(answered)")
        let registrations = await sessions.registrations
        check(registrations == 1, "the session is registered once: \(registrations)")
        let foundRegistered = await sessions.foundRegistered
        check(foundRegistered == count - 1, "and every other open finds it registered: \(foundRegistered)")
        let left = await turns.waiting(session)
        check(left == 0, "with none left waiting")
    }

    // MARK: A waiter whose task is cancelled leaves the line alone

    do {
        let turns = AgentOpenTurns()
        let session = UUID().uuidString
        let log = Log()
        let worker = Latch()
        let holder = Task {
            await turns.run(for: session) {
                await log.append("holder")
                await worker.wait()
            }
        }
        let held = await eventually { await log.lines == ["holder"] }
        check(held, "the turn is held")
        let cancelled = Task { await turns.run(for: session) { await log.append("cancelled") } }
        let joined = await eventually { await turns.waiting(session) == 1 }
        check(joined, "a waiter joins the line")
        let kept = Task { await turns.run(for: session) { await log.append("kept") } }
        let behind = await eventually { await turns.waiting(session) == 2 }
        check(behind, "and another after it")
        cancelled.cancel()
        let left = await eventually { await turns.waiting(session) == 1 }
        check(left, "the cancelled waiter leaves the line")
        let answer: Void? = await cancelled.value
        check(answer == nil, "and opens nothing")
        // A task cancelled before it asks for the turn is not lined up.
        let late = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await turns.run(for: session) { await log.append("late") }
        }
        late.cancel()
        let lateAnswer: Void? = await late.value
        let stillWaiting = await turns.waiting(session)
        check(lateAnswer == nil && stillWaiting == 1, "a task cancelled before it waits does not join the line")
        await worker.open()
        await holder.value
        await kept.value
        let lines = await log.lines
        check(lines == ["holder", "kept"], "the open under way and the one still waiting go on as they were: \(lines)")
    }
}
