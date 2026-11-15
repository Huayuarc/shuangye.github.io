import Foundation

/// Deleting a conversation (owner, 2026-10-30): any conversation the
/// sidebar lists, whatever it is called or holds, from its row's swipe and
/// long press or the chat's More menu. One still working — a turn, a
/// compaction, an approval waiting — is stopped first, as Stop stops it,
/// once the reader says so.
enum ChatDeletion {
    /// Where Delete was chosen.
    enum Origin {
        /// A row's swipe or long press: a conversation at rest goes at once,
        /// as it always has.
        case sidebarRow
        /// The chat's More menu, Delete Conversation…: it always asks.
        case moreMenu
    }

    /// What Delete asks before it deletes.
    enum Confirmation: Equatable {
        /// Delete, naming the conversation.
        case delete
        /// Stop and Delete: it is still working, and is stopped first.
        case stopAndDelete
    }

    /// The question Delete asks, or nil when it deletes at once.
    static func confirmation(for chat: ChatSummary, from origin: Origin) -> Confirmation? {
        if chat.isWorking {
            return .stopAndDelete
        }
        return origin == .moreMenu ? .delete : nil
    }
}
