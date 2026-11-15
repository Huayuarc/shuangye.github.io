import ApelinProtocol
import Foundation

/// Queued messages a stopped run never took (`queueDropped`), back in the
/// composer: oldest first, ahead of what the reader typed since, each with
/// the files it carried, as `ChatRecord.reclaimUnsent` puts back sends that
/// never got through.
enum DroppedMessages {
    struct Returned {
        var draft: ComposerDraft
        /// The messages put back.
        var messages: Int
        /// Files they carried that no longer read, left out.
        var attachmentsLeftOut: Int
    }

    /// The messages `ids` names, as their `queued` events in `events` sent
    /// them, merged into `draft`, which keeps its id: no message went under
    /// it. Nil when no event names one. `attachment` reads a message's file,
    /// nil when it no longer reads.
    static func returning(
        _ ids: Set<UUID>,
        from events: [TaskEvent],
        to draft: ComposerDraft,
        attachment: (AgentAttachment) -> ComposerAttachment?,
    ) -> Returned? {
        var remaining = ids
        var parts: [ComposerDraft] = []
        var leftOut = 0
        for event in events where event.kind == "queued" {
            guard let id = ChatTranscript.userMessageID(of: event), remaining.remove(id) != nil else { continue }
            let saved = ChatTranscript.attachments(in: event.payload?["attachments"])
            let files = saved.compactMap(attachment)
            leftOut += saved.count - files.count
            parts.append(ComposerDraft(text: event.payload?["text"]?.stringValue ?? "", attachments: files))
        }
        guard !parts.isEmpty else { return nil }
        parts.append(draft)
        var merged = draft
        merged.text = parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        merged.attachments = parts.flatMap(\.attachments)
        return Returned(draft: merged, messages: parts.count - 1, attachmentsLeftOut: leftOut)
    }
}
