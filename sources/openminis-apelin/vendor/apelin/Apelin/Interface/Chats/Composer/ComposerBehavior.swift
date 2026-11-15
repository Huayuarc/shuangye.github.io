// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Foundation

extension Notification.Name {
    static let composerBehaviorChanged = Notification.Name("wiki.qaq.apelin.composerBehaviorChanged")
}

/// How the composer treats return and a long paste. Every composer follows
/// a change at once.
enum ComposerBehavior {
    /// A paste longer than `longPasteThreshold` characters goes to the
    /// composer's delegate, to become an attachment, instead of the text.
    static var pasteLargeTextContentAsFile: Bool {
        get { UserDefaults.standard.object(forKey: "composer.pasteLargeTextContentAsFile") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "composer.pasteLargeTextContentAsFile")
            NotificationCenter.default.post(name: .composerBehaviorChanged, object: nil)
        }
    }

    /// Return inserts a new line and only the send button sends; otherwise
    /// return sends and ⌥ return inserts the new line.
    static var useConfirmationOnSend: Bool {
        get { UserDefaults.standard.bool(forKey: "composer.useConfirmationOnSend") }
        set {
            UserDefaults.standard.set(newValue, forKey: "composer.useConfirmationOnSend")
            NotificationCenter.default.post(name: .composerBehaviorChanged, object: nil)
        }
    }

    /// Characters past which a paste counts as long.
    static let longPasteThreshold = 512
}
