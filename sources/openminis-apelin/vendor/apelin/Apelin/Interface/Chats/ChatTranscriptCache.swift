import ApelinProtocol
import Foundation

/// The transcripts the runtime keeps, one per conversation, each brought up
/// to date only when what it shows changed. One is asked for after every
/// change to any conversation: each streamed batch, of this one or of
/// another streaming beside it. A batch is read onto the transcript the
/// ones before it made (`ChatTranscript.append`); only a sender's new title
/// has it built again from every event.
///
/// Kept for the conversations being followed and for the last other one
/// built, the page's, so browsing does not keep every history twice.
struct ChatTranscriptCache {
    private var entries: [UUID: Entry] = [:]
    private var unfollowed: UUID?

    /// `record`'s transcript: the one kept, while it still shows `record` at
    /// `now`, or brought up to date with the events since. `isFollowed` says
    /// which conversations a reader follows; `now`, `conversationTitle` and
    /// `attachment` are the transcript's.
    mutating func transcript(
        of record: ChatRecord,
        now: Date,
        isFollowed: (UUID) -> Bool,
        conversationTitle: (String) -> String?,
        attachment: (AgentAttachment) -> ComposerAttachment?,
    ) -> ChatTranscript {
        let id = record.summary.id
        let sending = (record.sending ?? []).map(Entry.Sent.init)
        var entry = entries.removeValue(forKey: id)
        let titlesHold = entry?.senderTitles.allSatisfy { conversationTitle($0.key) == $0.value } ?? false
        if titlesHold, let kept = entry, kept.shows(record, sending: sending, now: now) {
            entries[id] = kept
            return kept.transcript
        }
        let built: Entry
        if titlesHold, var kept = entry, kept.transcript.eventCount <= record.events.count {
            // Out of the table and held only here, so its rows change in
            // place rather than being copied first.
            entry = nil
            kept.catchUp(
                with: record,
                sending: sending,
                now: now,
                conversationTitle: conversationTitle,
                attachment: attachment,
            )
            built = kept
        } else {
            built = Entry(
                record,
                sending: sending,
                now: now,
                shown: entry?.transcript.messages,
                conversationTitle: conversationTitle,
                attachment: attachment,
            )
        }
        if !isFollowed(id) {
            unfollowed = id
        }
        entries = entries.filter { isFollowed($0.key) || $0.key == unfollowed }
        entries[id] = built
        return built.transcript
    }

    mutating func remove(_ id: UUID) {
        entries.removeValue(forKey: id)
    }

    /// `rows`, each one equal to its row in `shown` taken from there. The
    /// page compares the rows it shows with new ones and the list diffs them
    /// again; a row that is the very value shown before compares by its
    /// storage, where one built anew is read again text by text.
    static func reusing(_ shown: [ChatMessage], in rows: [ChatMessage]) -> [ChatMessage] {
        let earlier = Dictionary(shown.map { ($0.id, $0) }) { first, _ in first }
        return rows.map { row in
            guard let earlier = earlier[row.id], earlier == row else { return row }
            return earlier
        }
    }

    /// A transcript and what it was built from.
    private struct Entry {
        /// A message being sent, as its row shows it.
        struct Sent: Equatable {
            let id: UUID
            let text: String
            let attachments: [UUID]

            init(_ draft: ComposerDraft) {
                id = draft.id
                text = draft.text
                attachments = draft.attachments.map(\.id)
            }
        }

        /// It has read the record's first `transcript.eventCount` events;
        /// they are only ever appended to (`ChatRecord.take`).
        var transcript: ChatTranscript
        /// The time it judged the turn's quiet by.
        var builtAt: Date
        var sending: [Sent]
        /// The titles it names other conversations' messages by, by session
        /// ID, as it read them; a rename there shows here.
        var senderTitles: [String: String?] = [:]

        /// `record`'s transcript built from every event, each row that did
        /// not change taken from `shown`.
        init(
            _ record: ChatRecord,
            sending: [Sent],
            now: Date,
            shown: [ChatMessage]?,
            conversationTitle: (String) -> String?,
            attachment: (AgentAttachment) -> ComposerAttachment?,
        ) {
            var senderTitles: [String: String?] = [:]
            transcript = ChatTranscript(
                events: record.events,
                sending: record.sending ?? [],
                conversationTitle: { sessionID in
                    let title = conversationTitle(sessionID)
                    senderTitles.updateValue(title, forKey: sessionID)
                    return title
                },
                now: now,
                attachment: attachment,
            )
            if let shown {
                transcript.messages = ChatTranscriptCache.reusing(shown, in: transcript.messages)
            }
            builtAt = now
            self.sending = sending
            self.senderTitles = senderTitles
        }

        /// Whether it still shows `record`, whose messages on their way are
        /// `sending`, as a transcript built at `now` would, once its sender
        /// titles are known to hold: the same events and messages, and no
        /// quiet deadline passed since it was built, which a running summary
        /// would now stand in for.
        func shows(_ record: ChatRecord, sending: [Sent], now: Date) -> Bool {
            let wentQuiet = transcript.quietDeadline.map { builtAt < $0 && $0 <= now } ?? false
            return transcript.eventCount == record.events.count && self.sending == sending && !wentQuiet
        }

        /// Reads the events `record` gained since onto the transcript and
        /// shows it again with `sending` at `now`.
        mutating func catchUp(
            with record: ChatRecord,
            sending: [Sent],
            now: Date,
            conversationTitle: (String) -> String?,
            attachment: (AgentAttachment) -> ComposerAttachment?,
        ) {
            let shown = transcript.messages
            var looked: [String: String?] = [:]
            transcript.append(
                record.events[transcript.eventCount...],
                sending: record.sending ?? [],
                conversationTitle: { sessionID in
                    let title = conversationTitle(sessionID)
                    looked.updateValue(title, forKey: sessionID)
                    return title
                },
                now: now,
                attachment: attachment,
            )
            transcript.messages = ChatTranscriptCache.reusing(shown, in: transcript.messages)
            senderTitles.merge(looked) { _, latest in latest }
            builtAt = now
            self.sending = sending
        }
    }
}
