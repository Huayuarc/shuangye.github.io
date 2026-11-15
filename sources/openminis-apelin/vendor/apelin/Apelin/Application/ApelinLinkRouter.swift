import UIKit

/// Hands an `apelin://` link (`ApelinLink`) to the window that shows the
/// conversations: from the scene's URL contexts (a widget, the Live
/// Activity, another app, `uiopen`), and from a link tapped in a
/// conversation, which opens in place rather than through the system.
@MainActor
enum ApelinLinkRouter {
    /// Opens `url` when it is an `apelin:` link and says so; any other URL
    /// is left to its caller.
    @discardableResult
    static func open(_ url: URL, in scene: UIWindowScene?) -> Bool {
        guard let link = ApelinLink(url: url) else { return false }
        let scenes = ([scene] + UIApplication.shared.connectedScenes.map { $0 as? UIWindowScene }).compactMap(\.self)
        let root = scenes.lazy.flatMap(\.windows).compactMap { $0.rootViewController as? RootInterfaceController }.first
        root?.open(link)
        return true
    }
}
