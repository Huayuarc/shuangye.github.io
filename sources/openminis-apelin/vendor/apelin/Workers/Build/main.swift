import ApelinBuild
import ApelinProtocol

// apelin-build: Extensions, templates, projects and builds.
//
// Runs as mobile, spawned by apelind's session host with its socketpair as
// descriptor 3; WorkerMain does the assignment and the privilege check.
// Links ApelinCore, ApelinProtocol, ApelinProject, ApelinBuild — see AGENTS.md ▸ Decisions ▸ Process layout.
//
// Everything is ApelinBuild's BuildWorker; its doc comment is the contract.

/// The one BuildWorker, made from the assignment on the first request.
private final class WorkerBox: @unchecked Sendable {
    private let lock = PthreadLock()
    private var stored: BuildWorker?

    /// The worker if one was made.
    var made: BuildWorker? {
        lock.withLock { stored }
    }

    func worker(for assignment: WorkerAssignment) -> BuildWorker {
        lock.withLock {
            if let stored {
                return stored
            }
            let worker = BuildWorker(assignment: assignment)
            stored = worker
            return worker
        }
    }
}

private let box = WorkerBox()

WorkerMain.run(role: .build, onCancel: { taskID, context in
    box.worker(for: context.assignment).cancel(taskID)
}, onClose: {
    box.made?.killAll()
}) { request, context in
    await box.worker(for: context.assignment).handle(request) { taskID, kind, payload in
        context.emit(taskID, kind, payload)
    }
}
