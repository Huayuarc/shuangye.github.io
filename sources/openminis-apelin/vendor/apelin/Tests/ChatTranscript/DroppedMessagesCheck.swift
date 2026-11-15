import ApelinCore
import ApelinProtocol
import Foundation

/// Queued messages a stopped run never took go back to the composer whole —
/// text and files, oldest first — ahead of what was typed since, which
/// stays; the draft keeps its id.
func checkDroppedMessages() {
    func queued(_ seq: UInt64, _ id: UUID, _ text: String, files: [String] = []) -> TaskEvent {
        let attachments = files.map { path -> JSONValue in
            .object(["path": .string(path), "name": .string(path), "mimeType": .string("text/plain")])
        }
        return TaskEvent(seq: EventSeq(seq), kind: "queued", time: Date(timeIntervalSince1970: Double(seq)), payload: .object([
            "id": .string(id.uuidString), "text": .string(text), "attachments": .array(attachments),
        ]))
    }

    let notes = ComposerAttachment(name: "notes.md", data: Data("notes".utf8), text: "notes")
    let log = ComposerAttachment(name: "build.log", data: Data("log".utf8), text: "log")
    let files = ["Attachments/notes": notes, "Attachments/log": log]
    func read(_ item: AgentAttachment) -> ComposerAttachment? {
        files[item.path]
    }

    let first = UUID(), second = UUID(), taken = UUID()
    let events = [
        queued(1, first, "Build it", files: ["Attachments/notes"]),
        queued(2, taken, "Taken by the run"),
        TaskEvent(seq: EventSeq(3), kind: "prompt", time: Date(timeIntervalSince1970: 3), payload: .object([
            "id": .string(taken.uuidString), "text": .string("Taken by the run"),
        ])),
        queued(4, second, "And test it", files: ["Attachments/log"]),
    ]

    let empty = ComposerDraft()
    let both = DroppedMessages.returning([second, first], from: events, to: empty, attachment: read)
    precondition(both?.draft.text == "Build it\n\nAnd test it", "both, in the order they were sent: \(both?.draft.text ?? "nil")")
    precondition(both?.draft.attachments == [notes, log], "with the files they carried")
    precondition(both?.draft.id == empty.id && both?.messages == 2 && both?.attachmentsLeftOut == 0)

    let typed = ComposerDraft(text: "Typed later", attachments: [ComposerAttachment(name: "shot.png", data: Data([1]), isImage: true)])
    let merged = DroppedMessages.returning([first], from: events, to: typed, attachment: read)
    precondition(merged?.draft.text == "Build it\n\nTyped later", "what was typed since stays, after it: \(merged?.draft.text ?? "nil")")
    precondition(merged?.draft.attachments == [notes] + typed.attachments && merged?.draft.id == typed.id)

    let attachmentOnly = ComposerDraft(attachments: [notes])
    let intoFiles = DroppedMessages.returning([second], from: events, to: attachmentOnly, attachment: read)
    precondition(intoFiles?.draft.text == "And test it" && intoFiles?.draft.attachments == [log, notes],
                 "a draft of files alone adds no blank line")

    let gone = DroppedMessages.returning([first, second], from: events, to: empty) { $0.path == "Attachments/log" ? nil : read($0) }
    precondition(gone?.draft.text == "Build it\n\nAnd test it" && gone?.draft.attachments == [notes],
                 "a file that no longer reads is left out")
    precondition(gone?.attachmentsLeftOut == 1, "and counted, so the reader is told")

    let again = events + [queued(5, first, "Build it", files: ["Attachments/notes"])]
    precondition(DroppedMessages.returning([first], from: again, to: empty, attachment: read)?.draft.text == "Build it",
                 "a message queued twice under one id goes back once")
    precondition(DroppedMessages.returning([UUID()], from: events, to: typed, attachment: read) == nil,
                 "an id no queued message has puts nothing back")
    print("ok: dropped queued messages go back to the composer with their files, ahead of what was typed since")
}
