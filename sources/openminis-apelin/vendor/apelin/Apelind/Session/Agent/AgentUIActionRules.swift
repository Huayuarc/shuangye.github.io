import ApelinCore
import ApelinProtocol

/// An agent never operates Apelin's own screen: coordinate taps through
/// All Projects deleted a project with its chats, and the same taps could
/// approve a request, send a message as the user or change a setting. The
/// host names Apelin in every agent `uiAction` as an app it may not reach,
/// whatever the agent sent, and apelin-diagnostics refuses a target or a
/// foreground that is one, in every approval mode: no approval or preset
/// lifts it. The screen and the UI tree stay readable.
enum AgentUIActionRules {
    static let refusedBundleIDs = [DataFolder.bundleIdentifier]

    /// `request` as apelin-diagnostics is to serve it: an agent's refusing
    /// Apelin, anyone else's as it came.
    static func scoped(_ request: WireRequest, caller: Caller) throws -> WireRequest {
        guard caller.isAgent else { return request }
        var action = try request.decode(UIActionRequest.self)
        action.refusedBundleIDs = refusedBundleIDs
        var scoped = request
        scoped.payload = try JSONCoding.encode(action)
        return scoped
    }
}
