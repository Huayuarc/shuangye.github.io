import ApelinCore
import enum ApelinProtocol.AgentToolName
import Foundation

/// Arguments as the task's events record them: the token apelin_git_save_credential
/// carries is replaced, so it reaches the host's keychain request and no
/// event, transcript or log. The model's own copy is the user's message.
/// A reopened session relays its whole log again, so a call recorded under
/// a name an earlier release used is masked as well.
public enum ToolArgumentRedaction {
    static let mask = "••••••••"

    public static func redacted(_ arguments: String, tool: String) -> String {
        guard AgentToolName.canonical(tool) == .gitSaveCredential else { return arguments }
        guard case var .object(fields)? = try? JSONCoding.decode(JSONValue.self, from: Data(arguments.utf8)) else {
            // nothing readable to keep: none of it is shown
            return "{}"
        }
        if fields["token"] != nil {
            fields["token"] = .string(mask)
        }
        guard let data = try? JSONCoding.encode(JSONValue.object(fields)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
