#if canImport(ActivityKit)
    import ActivityKit
#endif
import Foundation

/// The Live Activity's contract between the app and the extension: no fixed
/// attributes, and the conversations in progress as its state.
///
/// From iOS 16.2, as iGhostVT's: `ActivityContent` and the request that
/// takes it are 16.2 API, and both targets link ActivityKit weakly
/// (`-weak_framework ActivityKit`), so iOS 16.0 and 16.1 load them and show
/// no activity.
@available(iOS 16.2, *)
struct ChatActivityAttributes {
    typealias ContentState = ChatWidgetSnapshot
}

#if canImport(ActivityKit)
    @available(iOS 16.2, *)
    extension ChatActivityAttributes: ActivityAttributes {}
#endif
