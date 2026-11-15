import Foundation
import ObjectiveC
import UserNotifications

/// Posts as the app, after Xrash's. `usernotificationsd` admits a center
/// made for another bundle only from a process whose
/// `com.apple.private.usernotifications.bundle-identifiers` names it, which
/// apelind's entitlements do; the banner is then the app's in every way —
/// its icon, its settings and authorization, and a tap opens it. Nothing
/// shows until the reader has allowed Apelin's notifications, which the app
/// asks for when they send their first message.
struct NoticePoster: @unchecked Sendable {
    private static let appBundleIdentifier = "wiki.qaq.apelin"
    /// The key the app reads a tapped banner's link from:
    /// `ConversationNotices.linkKey`.
    private static let linkKey = "link"

    private let center: UNUserNotificationCenter

    /// Nil when the OS no longer has the initializer, which is asked rather
    /// than assumed: it is not in the SDK.
    init?() {
        let selector = NSSelectorFromString("initWithBundleIdentifier:")
        guard let method = class_getInstanceMethod(UNUserNotificationCenter.self, selector),
              let allocated = (UNUserNotificationCenter.self as AnyObject)
                  .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return nil }
        typealias Initializer = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let made = initialize(allocated, selector, Self.appBundleIdentifier as NSString)
        guard let center = made?.takeUnretainedValue() as? UNUserNotificationCenter else { return nil }
        self.center = center
    }

    func post(_ notice: AgentNotice) {
        let content = UNMutableNotificationContent()
        content.title = Self.string(notice.title)
        if let subtitle = notice.subtitle {
            content.subtitle = Self.string(subtitle)
        }
        if let body = notice.body {
            content.body = Self.string(body)
        }
        // One stack per conversation, which the app clears when it is opened.
        content.threadIdentifier = notice.sessionID
        content.sound = .default
        content.userInfo = [Self.linkKey: notice.link]
        center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)) { error in
            if let error {
                NSLog("apelind-session: notification \(notice.identifier) not posted: \(error)")
            }
        }
    }

    private static func string(_ text: AgentNotice.Text) -> String {
        switch text {
        case let .verbatim(value): value
        case let .key(key): NSString.localizedUserNotificationString(forKey: key, arguments: nil)
        }
    }
}

extension AgentNotices {
    /// The session host's: marks in `notices.json` beside its other state,
    /// banners through `NoticePoster`, or nowhere when the OS has no center
    /// to post as the app through.
    init(stateDirectory: URL, sessions: URL) {
        let poster = NoticePoster()
        self.init(file: stateDirectory.appendingPathComponent("notices.json"), sessions: sessions) { notice in
            poster?.post(notice)
        }
    }
}
