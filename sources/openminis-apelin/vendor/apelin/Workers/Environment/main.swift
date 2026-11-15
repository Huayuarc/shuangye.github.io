import ApelinEnvironment
import ApelinProtocol

// apelin-environment: toolchain setup and removal, the SDK manager and the git service.
//
// Runs as mobile, spawned by apelind's session host with its socketpair as
// descriptor 3; WorkerMain does the assignment and the privilege check.
// Links ApelinCore, ApelinProtocol, ApelinEnvironment, ApelinGit — see AGENTS.md ▸ Decisions ▸ Process layout.
//
// Everything is served by EnvironmentWorker (Packages/ApelinKit/Sources/ApelinEnvironment).

let box = WorkerBox()

WorkerMain.run(
    role: .environment,
    onCancel: { taskID, context in box.worker(context).cancel(taskID) },
    handler: { request, context in await box.worker(context).handle(request) },
)

/// The one EnvironmentWorker, made on the first request, once the
/// assignment is known.
final class WorkerBox: @unchecked Sendable {
    private let lock = PthreadLock()
    private var made: EnvironmentWorker?

    func worker(_ context: WorkerContext) -> EnvironmentWorker {
        lock.withLock {
            if let made {
                return made
            }
            let worker = EnvironmentWorker(context: context)
            made = worker
            return worker
        }
    }
}
