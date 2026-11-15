import ApelinCore
import ApelinProtocol

extension ConsoleRunner {
    struct Replay {
        struct Following {
            var index: Int
            var handle: TaskHandle
            var response: JSONValue?
            var events: [JSONValue]
        }

        var results: [String: ConsoleStepResult] = [:]
        var lastResult: (index: Int, op: String, result: ConsoleStepResult)?
        var lastStarted: Int?
        /// A `run.resumed` line comes after the last `step.result`: an earlier
        /// launch already went on from there.
        var resumedAfterLastResult = false
        /// The step that was following a task when the output stops.
        var following: Following?
    }

    /// The step results an output file recorded, rebuilt from its
    /// `step.task`, `step.event` and `step.result` lines.
    static func replay(_ lines: [JSONValue]) -> Replay {
        var replay = Replay()
        var events: [Int: [JSONValue]] = [:]
        var tasks: [Int: (TaskHandle, JSONValue?)] = [:]
        var finished = Set<Int>()
        for line in lines {
            if line["type"]?.stringValue == "run.resumed" {
                replay.resumedAfterLastResult = true
            }
            guard let index = line["index"]?.doubleValue.map({ Int($0) }) else { continue }
            switch line["type"]?.stringValue {
            case "step.start":
                replay.lastStarted = index
                // A step run again (a resume from the step after a respring)
                // starts clean.
                events[index] = nil
                tasks[index] = nil
                finished.remove(index)
            case "step.task":
                if let taskID = line["taskID"]?.stringValue,
                   let kind = line["kind"]?.stringValue.flatMap(TaskKind.init(rawValue:))
                {
                    tasks[index] = (TaskHandle(taskID: TaskID(taskID), kind: kind), line["response"])
                }
            case "step.event":
                if let event = line["event"] {
                    events[index, default: []].append(event)
                }
            case "step.result":
                finished.insert(index)
                replay.resumedAfterLastResult = false
                var result = ConsoleStepResult(
                    ok: line["ok"] == .bool(true),
                    response: line["response"],
                    error: line["error"],
                )
                result.events = events[index] ?? []
                result.state = line["state"]?.stringValue
                if let label = line["label"]?.stringValue {
                    replay.results[label] = result
                }
                replay.lastResult = (index, line["op"]?.stringValue ?? "", result)
            default:
                break
            }
        }
        if let index = replay.lastStarted, !finished.contains(index), let (handle, response) = tasks[index] {
            replay.following = Replay.Following(
                index: index,
                handle: handle,
                response: response,
                events: events[index] ?? [],
            )
        }
        return replay
    }
}
