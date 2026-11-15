import enum ApelinProtocol.AgentToolName
import KWWKAI

/// A transcript recorded before the tools were renamed, in today's names:
/// the calls, their results and kwwk's record of the tools declared then
/// (its `SystemMessage`s). A reopened session then sends every provider a
/// history whose calls name the tools the request offers, and the model
/// never sees an old name to call. Text is left as it was, and so is any
/// name no release of Apelin gave (an MCP tool's).
enum LegacyToolNames {
    static func migrate(_ messages: [Message]) -> [Message] {
        messages.map { message in
            switch message {
            case var .assistant(assistant):
                assistant.content = assistant.content.map { block in
                    guard case var .toolCall(call) = block else { return block }
                    call.name = current(call.name)
                    return .toolCall(call)
                }
                return .assistant(assistant)
            case var .toolResult(result):
                result.toolName = current(result.toolName)
                return .toolResult(result)
            case var .system(system):
                system.toolsAdded = system.toolsAdded?.map { tool in
                    var tool = tool
                    tool.name = current(tool.name)
                    return tool
                }
                system.toolsRemoved = system.toolsRemoved?.map(current)
                return .system(system)
            case .user:
                return message
            }
        }
    }

    private static func current(_ name: String) -> String {
        AgentToolName.legacyNames[name]?.rawValue ?? name
    }
}
