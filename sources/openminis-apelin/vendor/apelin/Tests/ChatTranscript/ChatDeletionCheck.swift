import ApelinProtocol
import Foundation

/// Every conversation the sidebar lists offers Delete, whatever it is
/// called or holds, with Stop beside it while it works (`ChatRowAction`);
/// Delete asks first from the More menu always and from a row only while
/// the conversation works, which it then stops first (`ChatDeletion`).
func checkChatDeletion() {
    let untitled = ChatSummary.untitled(lastInteraction: Date(), projectName: "Clock")
    var pinnedUntitled = untitled
    pinnedUntitled.isPinned = true
    let named = ChatRecord(
        summary: ChatSummary(title: "Hook the clock", lastInteraction: Date(), projectName: "Clock"),
        sessionID: UUID().uuidString.lowercased(),
    )
    // one an agent opened, taken in at launch before its session had a title
    let opened = AgentSessionSummary(
        sessionID: UUID().uuidString.lowercased(),
        task: TaskHandle(taskID: TaskID("opened-task"), kind: .agent),
        state: .running,
        updatedAt: Date(),
        parentSessionID: named.sessionID,
    )
    guard let adopted = ChatAdoption.record(session: opened, records: [named])?.summary else {
        preconditionFailure("the conversation an agent opened is taken in")
    }
    precondition(untitled.isUntitled && adopted.isUntitled, "both still untitled")

    for chat in [untitled, pinnedUntitled, named.summary, adopted] {
        precondition(ChatRowAction.trailingSwipe(for: chat) == [.delete], "a row at rest swipes to Delete: \(chat)")
        precondition(ChatRowAction.menu(for: chat).last == .delete, "and its long press ends on Delete: \(chat)")
        var working = chat
        working.isWorking = true
        precondition(ChatRowAction.trailingSwipe(for: working) == [.delete, .stop], "one that works keeps Delete beside Stop")
        precondition(ChatRowAction.menu(for: working).first == .stop, "and its long press starts with Stop")
        precondition(ChatRowAction.menu(for: working).last == .delete)
    }
    precondition(ChatRowAction.menu(for: untitled) == [.pin, .delete])
    precondition(ChatRowAction.menu(for: pinnedUntitled) == [.unpin, .delete], "a pinned one unpins")
    precondition(ChatRowAction.leadingSwipe(for: pinnedUntitled) == [.unpin])
    precondition(ChatRowAction.leadingSwipe(for: untitled) == [.pin])

    var working = named.summary
    working.isWorking = true
    precondition(ChatDeletion.confirmation(for: named.summary, from: .sidebarRow) == nil, "a row at rest deletes at once")
    precondition(ChatDeletion.confirmation(for: untitled, from: .sidebarRow) == nil)
    precondition(ChatDeletion.confirmation(for: named.summary, from: .moreMenu) == .delete, "the More menu always asks")
    precondition(ChatDeletion.confirmation(for: untitled, from: .moreMenu) == .delete)
    precondition(ChatDeletion.confirmation(for: working, from: .sidebarRow) == .stopAndDelete, "a working one is stopped first")
    precondition(ChatDeletion.confirmation(for: working, from: .moreMenu) == .stopAndDelete)
    print("ok: every conversation offers Delete, and one still working is stopped first")
}
