import ApelinCore
import ApelinProtocol
import Foundation

/// The builds a conversation's new events say completed, for the star
/// prompt: each apelin_project_build call whose result says the build
/// succeeded. A failed build is a result too, with `succeeded` false, and
/// a refused one an error, so neither counts. Nor does an answer the
/// session cut at 64 KB (hundreds of warnings): `succeeded`, the last of
/// its sorted keys, is what the cut takes.
enum CompletedBuilds {
    static func count(in events: [TaskEvent]) -> Int {
        events.filter(isCompletedBuild).count
    }

    static func isCompletedBuild(_ event: TaskEvent) -> Bool {
        guard event.kind == "toolResult",
              let payload = event.payload,
              payload["tool"]?.stringValue == AgentToolName.projectBuild.rawValue,
              payload["isError"]?.boolValue != true,
              let output = payload["output"]?.stringValue,
              let result = try? JSONDecoder().decode(BuildResult.self, from: Data(output.utf8))
        else { return false }
        return result.succeeded
    }

    /// The one field of the tool's answer this reads.
    private struct BuildResult: Decodable {
        let succeeded: Bool
    }
}
