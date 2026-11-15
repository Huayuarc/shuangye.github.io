import ApelinCore
import ApelinProtocol
import Foundation

/// A build counts for the star prompt only when apelin_project_build
/// answered that it succeeded: not a failed build, a refused call, another
/// tool or the call itself.
func checkCompletedBuilds() {
    func result(_ seq: UInt64, tool: String, output: String, isError: Bool = false) -> TaskEvent {
        TaskEvent(seq: EventSeq(seq), kind: "toolResult", time: Date(timeIntervalSince1970: Double(seq)), payload: .object([
            "id": .string("b\(seq)"), "tool": .string(tool), "output": .string(output), "isError": .bool(isError),
        ]))
    }
    let build = AgentToolName.projectBuild.rawValue
    // as the tool encodes its answer: pretty-printed, keys sorted
    let succeeded = """
    {
      "artifacts" : [],
      "buildID" : "b1",
      "diagnostics" : [],
      "logExcerpt" : "ok",
      "succeeded" : true
    }
    """
    let failed = succeeded.replacingOccurrences(of: "\"succeeded\" : true", with: "\"succeeded\" : false")
    let events = [
        TaskEvent(seq: EventSeq(1), kind: "toolCall", time: Date(timeIntervalSince1970: 1), payload: .object([
            "id": .string("b1"), "tool": .string(build), "arguments": .string("{}"),
        ])),
        result(2, tool: build, output: succeeded),
        result(3, tool: build, output: failed),
        result(4, tool: build, output: "refused: the build description could not be checked", isError: true),
        result(5, tool: build, output: succeeded, isError: true),
        result(6, tool: AgentToolName.shellRun.rawValue, output: succeeded),
        result(7, tool: "build", output: succeeded),
        result(8, tool: build, output: "{\"succeeded\" : tr"),
        result(9, tool: build, output: succeeded),
    ]
    precondition(CompletedBuilds.isCompletedBuild(events[1]), "a build that succeeded")
    precondition(!CompletedBuilds.isCompletedBuild(events[0]), "the call is no result")
    precondition(!CompletedBuilds.isCompletedBuild(events[2]), "a failed build")
    precondition(!CompletedBuilds.isCompletedBuild(events[3]) && !CompletedBuilds.isCompletedBuild(events[4]), "a refused call")
    precondition(!CompletedBuilds.isCompletedBuild(events[5]), "another tool that printed the same")
    precondition(!CompletedBuilds.isCompletedBuild(events[6]), "a name no fresh event carries")
    precondition(!CompletedBuilds.isCompletedBuild(events[7]), "an answer cut short")
    precondition(CompletedBuilds.count(in: events) == 2, "two builds completed")
    precondition(CompletedBuilds.count(in: []) == 0)
    print("ok: a build counts once it succeeded")
}
