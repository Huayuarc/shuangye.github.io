import Foundation

/// The order the sidebar lists a project's conversations in: the pinned
/// ones first, then the rest under the day the reader last started or wrote
/// in each, newest first (`ChatSummary.lastInteraction`). Nothing an agent
/// does changes it, so the list holds still while conversations work.
enum SidebarOrder {
    struct Sections: Equatable {
        /// The pinned conversations, newest first.
        var pinned: [UUID] = []
        /// Every day a conversation is listed under, pinned or not, newest
        /// first. A day of pinned ones alone has no rows, and stays for a
        /// row unpinned into it to move to (`SidebarController`).
        var days: [Day] = []
    }

    struct Day: Equatable {
        /// Its start, in the calendar the list was made in.
        var start: Date
        /// The conversations under it that are not pinned, newest first.
        var chats: [UUID]
    }

    /// Newest first; two of the same moment by id, so the order never
    /// depends on how the conversations were held.
    static func newestFirst(_ chats: [ChatSummary]) -> [ChatSummary] {
        chats.sorted { lhs, rhs in
            if lhs.lastInteraction != rhs.lastInteraction {
                return lhs.lastInteraction > rhs.lastInteraction
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The conversation a project opens on: the reader's latest, pinned or not.
    static func newest(_ chats: [ChatSummary]) -> ChatSummary? {
        newestFirst(chats).first
    }

    /// `chats` as the sidebar lists them, by the days of `calendar`.
    static func sections(of chats: [ChatSummary], calendar: Calendar = .current) -> Sections {
        var sections = Sections()
        for chat in newestFirst(chats) {
            let start = calendar.startOfDay(for: chat.lastInteraction)
            if sections.days.last?.start != start {
                sections.days.append(Day(start: start, chats: []))
            }
            if chat.isPinned {
                sections.pinned.append(chat.id)
            } else {
                sections.days[sections.days.count - 1].chats.append(chat.id)
            }
        }
        return sections
    }
}
