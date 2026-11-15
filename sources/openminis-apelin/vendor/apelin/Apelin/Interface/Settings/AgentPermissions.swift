import ApelinProtocol
import Foundation

/// Two device-wide choices, the mode and Ask Before Using the Screen,
/// synchronized to the receiving session on every send.
enum AgentPermissions {
    static var mode: ApprovalMode {
        get {
            UserDefaults.standard.string(forKey: "agent.permissionMode")
                .flatMap(ApprovalMode.init(rawValue:)) ?? .relaxed
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "agent.permissionMode") }
    }

    /// Ask Before Using the Screen (owner, 2026-10-30): on unless the reader
    /// turned it off. While on, the agent asks before every UI tree read,
    /// UI action and icli command, in every mode, and the host holds it to
    /// that (`ScreenConsent`).
    static var asksBeforeScreen: Bool {
        get { UserDefaults.standard.object(forKey: "agent.asksBeforeScreen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "agent.asksBeforeScreen") }
    }

    static func title(for mode: ApprovalMode) -> String {
        switch mode {
        case .confirm: String(localized: "Strict")
        case .relaxed: String(localized: "Relaxed")
        case .full: String(localized: "Full")
        }
    }

    static var explanation: String {
        String(localized: "Strict: asks before commands and sensitive changes.\n\nRelaxed: runs these operations without asking, within the app’s permissions, but asks before any command that runs as root.\n\nFull: runs commands as root without asking too.")
    }
}
