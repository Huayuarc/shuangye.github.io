import ApelinCore
import ApelinLogReader
import ApelinProtocol
import Foundation

/// `apelin-log-reader`: the root half of `logStream`, started by the session
/// host only when apelin-diagnostics cannot read the live log as mobile. It
/// serves one operation over a filter the wire fixes — no path, no
/// predicate, no program — and answers bounded `log` events. System code
/// only: ApelinLogReader (Foundation, libobjc, LoggingSupport opened at run
/// time), ApelinCore, ApelinProtocol.
public enum LogReaderWorker {
    public static func main() -> Never {
        let pump = LogStreamPump(source: SystemLogReader())
        WorkerMain.run(role: .logReader, onCancel: { taskID, _ in
            pump.cancel(taskID)
        }) { request, context in
            switch request.request.operation {
            case .logStream:
                serve(request, context: context, pump: pump)
            default:
                WorkerMain.unimplemented(request)
            }
        }
    }

    /// Starts the stream for the host's task; the reply is its acceptance.
    public static func serve(
        _ request: ChannelRequest,
        context: WorkerContext,
        pump: LogStreamPump,
    ) -> (WireReply, [OwnedDescriptor]) {
        let requestID = request.request.requestID
        do {
            guard let taskID = request.taskID else {
                throw ApelinError(.badRequest, "A logStream request needs a task ID.")
            }
            let stream = try request.request.decode(LogStreamRequest.self)
            try pump.start(
                stream,
                taskID: taskID,
                emit: { kind, payload in context.emit(taskID, kind, payload) },
                finish: { state, message in context.finish(taskID, state, message: message) },
            )
            return (.success(requestID, Acknowledged()), [])
        } catch let error as ApelinError {
            return (.failure(requestID, error), [])
        } catch {
            return (.failure(requestID, ApelinError(.internal, String(describing: error))), [])
        }
    }
}
