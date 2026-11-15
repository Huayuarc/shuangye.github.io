import Foundation

/// What a conversation's row in the sidebar offers by its swipes and its
/// long press. Delete is always there: a conversation's name or contents
/// never take it away (`ChatDeletion`).
enum ChatRowAction: Equatable {
    case pin
    case unpin
    case stop
    case delete

    /// The leading swipe: Pin, or Unpin for a pinned one.
    static func leadingSwipe(for chat: ChatSummary) -> [ChatRowAction] {
        [chat.isPinned ? .unpin : .pin]
    }

    /// The trailing swipe, from the row's edge in: Delete, and Stop beside
    /// it while the conversation works. Never empty: a row given no action
    /// of its own gets UIKit's default Delete, which this list's data source
    /// does nothing with.
    static func trailingSwipe(for chat: ChatSummary) -> [ChatRowAction] {
        chat.isWorking ? [.delete, .stop] : [.delete]
    }

    /// The long press: Stop first while it works, then Pin or Unpin, then
    /// Delete.
    static func menu(for chat: ChatSummary) -> [ChatRowAction] {
        (chat.isWorking ? [.stop] : []) + leadingSwipe(for: chat) + [.delete]
    }
}
