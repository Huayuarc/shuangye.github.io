import Foundation

/// The order the sidebar's project menu lists projects in, and which of
/// them wait under More Projects. A project is as recent as the newest
/// conversation the reader started or wrote in it
/// (`ChatSummary.lastInteraction`), or as its folder's making when that is
/// later, so a project an agent made or a file brought in comes first
/// until the reader works somewhere newer. The newest five are listed at
/// the top, and the open project with them wherever it falls; the rest,
/// newest first too, under More Projects.
enum ProjectMenuOrder {
    /// How many projects the menu lists before More Projects.
    static let topCount = 5

    struct Split: Equatable {
        /// Listed at the top, newest first.
        var top: [String] = []
        /// Listed under More Projects, newest first; empty when there is
        /// no need for it.
        var more: [String] = []
    }

    /// `projects` by folder name, with when each folder was made where it
    /// is known; two of the same moment by name.
    static func split(
        _ projects: [String],
        created: [String: Date],
        chats: [ChatSummary],
        open: String?,
    ) -> Split {
        var latest = created
        for chat in chats {
            guard let name = chat.projectName else { continue }
            latest[name] = max(latest[name] ?? .distantPast, chat.lastInteraction)
        }
        let newestFirst = projects.sorted { lhs, rhs in
            let left = latest[lhs] ?? .distantPast
            let right = latest[rhs] ?? .distantPast
            if left != right {
                return left > right
            }
            return lhs < rhs
        }
        let newest = Set(newestFirst.prefix(topCount))
        var split = Split()
        for name in newestFirst {
            if newest.contains(name) || name == open {
                split.top.append(name)
            } else {
                split.more.append(name)
            }
        }
        return split
    }
}
