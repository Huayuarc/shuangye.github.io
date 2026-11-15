import ApelinCore
import ApelinProtocol

/// Ask Before Using the Screen (`ScreenConsent`, owner, 2026-10-30): while
/// the app says a session asks, its agent reads the UI tree, acts on the
/// screen and runs icli (or another of `ScreenConsent.programs`) only by
/// spending one approval the app gave that session whose own
/// `approvalRequested` names exactly that call, in every approval mode: the
/// tree read or the action as the host is asked for it, the command and its
/// working directory as shell_run runs them. One approval covers one call,
/// nothing is granted for the session, and `agentClose` forgets what is
/// left. The app's and the console's own calls are untouched, and so is a
/// screenshot, which stays the conversation's rule.
enum AgentScreenRules {
    /// The refusal for an agent's `readUITree` or `uiAction` that the
    /// session's setting holds back and no approval covers, after spending
    /// the one that does; nil lets it through. Any other caller and
    /// operation passes.
    static func authorize(_ request: WireRequest, caller: Caller, registry: TaskRegistry) async -> ApelinError? {
        guard case let .worker(.agent, session) = caller,
              request.operation == .readUITree || request.operation == .uiAction
        else { return nil }
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard entry.asksBeforeScreen else { return nil }
        let covers: (JSONValue) -> Bool
        let what: String
        do {
            if request.operation == .readUITree {
                let tree = try request.decode(ReadUITreeRequest.self)
                covers = { Self.covers(tree, asked: $0) }
                what = "reading the screen"
            } else {
                let action = try request.decode(UIActionRequest.self)
                covers = { Self.covers(action, asked: $0) }
                what = "this action on the screen"
            }
        } catch {
            return ApelinError(.badRequest, "\(request.operation.rawValue) could not be read")
        }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: covers) else {
            return ApelinError(
                .denied,
                "approval required: Ask Before Using the Screen is on, and the user has not approved \(what) with this call",
            )
        }
        return nil
    }

    /// Spends the approval `run` cites when the user gave it for exactly
    /// this command, as root or not, in this working directory, on a card
    /// that said it uses the screen; throws otherwise, leaving it unspent.
    static func spend(_ run: AgentRunCodeRequest, entry: AgentSessionTable.Entry, registry: TaskRegistry) async throws {
        guard case let .user(approvalID) = run.approval else {
            throw ApelinError(
                .denied,
                "approval required: Ask Before Using the Screen is on, and this command runs a program that opens apps and links or reads and acts on the screen; it needs the user's approval of this call, every time",
            )
        }
        let asked = await AgentApprovals.requested(approvalID, entry: entry, registry: registry)
        guard let asked, covers(run, asked: asked) else {
            throw ApelinError(.denied, "\(approvalID) is not the user's approval of this command, which uses the screen")
        }
        guard await AgentSessionTable.shared.consume(entry.sessionID, approvalID: approvalID) else {
            throw ApelinError(.denied, "the app has not approved \(approvalID)")
        }
    }

    /// The `detail.screenControl` of `asked` when it is for `operation` and
    /// `tool`.
    private static func marker(_ asked: JSONValue, operation: AppOperation, tool: AgentToolName) -> JSONValue? {
        guard asked["tool"]?.stringValue == tool.rawValue,
              let marker = asked["detail"]?[ScreenConsent.detailKey],
              marker["operation"]?.stringValue == operation.rawValue
        else { return nil }
        return marker
    }

    /// Whether `asked` approves exactly this read of the UI tree.
    static func covers(_ tree: ReadUITreeRequest, asked: JSONValue) -> Bool {
        guard let shown = try? marker(asked, operation: .readUITree, tool: .screenReadTree)?["request"]?
            .decode(ReadUITreeRequest.self)
        else { return false }
        return shown.targetID == tree.targetID
    }

    /// Whether `asked` approves exactly this action, in this target: what
    /// the host adds to it (`refusedBundleIDs`) is not part of it.
    static func covers(_ action: UIActionRequest, asked: JSONValue) -> Bool {
        guard let shown = try? marker(asked, operation: .uiAction, tool: .screenInteract)?["request"]?
            .decode(UIActionRequest.self)
        else { return false }
        return shown.targetID == action.targetID && shown.action == action.action
    }

    /// Whether `asked` approves exactly this command in this working
    /// directory: a root one only on a root card (`rootCommand`), an
    /// ordinary one only on an ordinary card (`command`).
    static func covers(_ run: AgentRunCodeRequest, asked: JSONValue) -> Bool {
        let key = run.asRoot == true ? RunCodeApproval.rootCommandDetail : "command"
        guard marker(asked, operation: .agentRunCode, tool: .shellRun) != nil,
              let approved = AgentApprovals.approvedSpec(asked, key: key), approved == run.spec
        else { return false }
        return AgentApprovals.directoryName(asked["workingDirectory"]?.stringValue)
            == AgentApprovals.directoryName(run.workingDirectory)
    }
}
