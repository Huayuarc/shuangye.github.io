import Foundation

/// Reading `events.jsonl`: the opening scan, which decodes almost nothing,
/// and the replay, which decodes a chunk at a time outside the actor.
extension SessionEventLog {
    /// What opening a session needs from its log.
    struct Summary: Sendable, Equatable {
        /// The last record's number.
        var lastSeq: UInt64 = 0
        /// Every `userMessage` id: the same message sent again is a duplicate.
        var userMessageIDs: Set<UUID> = []
        var hasTitle = false
        /// Approvals asked and never resolved, in the order asked.
        var openApprovals: [String] = []

        /// The kinds of event `add` reads, as the encoder spells their
        /// cases: the only lines the opening scan decodes, but for the last.
        static let kinds: Set<String> = ["userMessage", "titleUpdated", "approvalRequested", "approvalResolved"]

        init() {}

        /// What a log of `records` holds, every one of them read.
        init(_ records: [SessionEventRecord]) {
            for record in records {
                add(record)
            }
        }

        mutating func add(_ record: SessionEventRecord) {
            lastSeq = record.seq
            switch record.event {
            case let .userMessage(id, _, _): userMessageIDs.insert(id)
            case .titleUpdated: hasTitle = true
            case let .approvalRequested(request): openApprovals.append(request.id)
            case let .approvalResolved(id, _): openApprovals.removeAll { $0 == id }
            default: break
            }
        }
    }

    /// How much of the file a replay reads at a time.
    static let replayChunkBytes = 1 << 20

    private static let newline = UInt8(ascii: "\n")
    private static let quote = UInt8(ascii: "\"")
    /// How each line the encoder writes begins, and what follows its date.
    private static let dateKey = Array(#"{"date":""#.utf8)
    private static let eventKey = Array(#"","event":{""#.utf8)

    /// One pass over the log's bytes, read once: where its whole lines end
    /// (a torn last line left out) and its `Summary`. A line is decoded
    /// only where the summary reads its kind, where its kind cannot be read
    /// from its bytes, and for the last line's number. One of those that
    /// will not decode is `corrupt`, but for the last line, which a process
    /// killed mid-write leaves torn.
    static func scan(_ url: URL) throws -> (summary: Summary, length: Int, size: Int, decodes: Int) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try data.withUnsafeBytes { bytes in
            var summary = Summary()
            var decodes = 0
            func decode(_ line: Range<Int>) -> SessionEventRecord? {
                decodes += 1
                return try? decoder.decode(SessionEventRecord.self, from: Data(UnsafeRawBufferPointer(rebasing: bytes[line])))
            }
            // What follows the last newline is a write cut short.
            var length = bytes.count
            while length > 0, bytes[length - 1] != newline {
                length -= 1
            }
            let last = lastLine(in: bytes, before: length)
            var number = 0
            try forEachLine(in: bytes, upTo: last?.lowerBound ?? 0) { line in
                number += 1
                if let kind = kind(of: UnsafeRawBufferPointer(rebasing: bytes[line])), !Summary.kinds.contains(kind) {
                    return
                }
                guard let record = decode(line) else { throw SessionStoreError.corrupt("line \(number)") }
                summary.add(record)
            }
            guard let last else { return (summary, length, bytes.count, decodes) }
            number += 1
            if let record = decode(last) {
                summary.add(record)
            } else if length < bytes.count {
                // the torn write is the one after it
                throw SessionStoreError.corrupt("line \(number)")
            } else {
                // A last line that will not decode is torn too.
                length = last.lowerBound
                summary.lastSeq = 0
                if let previous = lastLine(in: bytes, before: length) {
                    guard let record = decode(previous) else { throw SessionStoreError.corrupt("line \(number - 1)") }
                    summary.lastSeq = record.seq
                }
            }
            return (summary, length, bytes.count, decodes)
        }
    }

    /// The case a line's event names, read from its bytes without decoding
    /// it: the encoder sorts keys, so each line it writes begins
    /// `{"date":"<date>","event":{"<case>":`. Nil for a line laid out any
    /// other way, which is then decoded instead.
    ///
    /// It runs once a line on every open, so it compares with `memcmp` and
    /// searches with `memchr`, as `forEachLine` does.
    static func kind(of line: UnsafeRawBufferPointer) -> String? {
        guard let base = line.baseAddress, line.count > dateKey.count,
              memcmp(base, dateKey, dateKey.count) == 0,
              // a date holds no quote
              let dateEnd = memchr(base + dateKey.count, Int32(quote), min(40, line.count - dateKey.count))
        else { return nil }
        let eventStart = base.distance(to: UnsafeRawPointer(dateEnd))
        let kindStart = eventStart + eventKey.count
        guard line.count > kindStart, memcmp(base + eventStart, eventKey, eventKey.count) == 0,
              let kindQuote = memchr(base + kindStart, Int32(quote), min(64, line.count - kindStart))
        else { return nil }
        let kindEnd = base.distance(to: UnsafeRawPointer(kindQuote))
        guard kindEnd > kindStart, kindEnd + 1 < line.count, line[kindEnd + 1] == UInt8(ascii: ":") else { return nil }
        let name = UnsafeRawBufferPointer(rebasing: line[kindStart ..< kindEnd])
        for byte in name where !isNameByte(byte) {
            return nil
        }
        return String(decoding: name, as: UTF8.self)
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }

    /// Yields each record after `afterSeq` that the log's first `length`
    /// bytes hold, as it reads them; answers how many lines it decoded.
    /// Each chunk's records are decoded before any is yielded, so a reader
    /// faster than the decoding wakes once a chunk, not once a record. A
    /// line that will not decode is read past and stands as an `error`
    /// numbered after the record before it (the writer numbers its lines
    /// one by one); a file that cannot be read stands as one `error`
    /// numbered `lastSeq`, the last record written at the attach, so what
    /// follows is still in order.
    static func replay(
        _ url: URL,
        length: UInt64,
        afterSeq: UInt64,
        lastSeq: UInt64,
        to continuation: AsyncStream<SessionEventRecord>.Continuation,
        pausing pause: (@Sendable () async -> Void)?,
    ) async -> Int {
        var decodes = 0
        var seq: UInt64 = 0
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var offset: UInt64 = 0
            var carry = Data()
            while offset < length {
                try Task.checkCancellation()
                let count = Int(min(UInt64(replayChunkBytes), length - offset))
                guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else {
                    throw SessionStoreError.io("events.jsonl ended early")
                }
                offset += UInt64(chunk.count)
                carry.append(chunk)
                var records: [SessionEventRecord] = []
                let read = carry.withUnsafeBytes { bytes in
                    forEachLine(in: bytes, upTo: bytes.count) { line in
                        decodes += 1
                        let data = Data(UnsafeRawBufferPointer(rebasing: bytes[line]))
                        let record = (try? decoder.decode(SessionEventRecord.self, from: data)) ?? SessionEventRecord(
                            seq: seq + 1,
                            date: Date(),
                            event: .error(message: "Part of this chat's history could not be read."),
                        )
                        seq = record.seq
                        records.append(record)
                    }
                }
                carry = carry.subdata(in: read ..< carry.count)
                for record in records where record.seq > afterSeq {
                    continuation.yield(record)
                }
                await pause?()
            }
        } catch is CancellationError {
            // the subscriber has gone
        } catch {
            if seq < lastSeq {
                continuation.yield(SessionEventRecord(
                    seq: lastSeq,
                    date: Date(),
                    event: .error(message: "The rest of this chat's history could not be read: \(error.localizedDescription)"),
                ))
            }
        }
        return decodes
    }

    /// Valid records in order, every line decoded, and how many it
    /// decoded. A torn last line (the process died mid-write) is dropped;
    /// damage elsewhere is an error.
    static func readRecords(_ url: URL) throws -> (records: [SessionEventRecord], decodes: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], 0) }
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var records: [SessionEventRecord] = []
        for (index, line) in lines.enumerated() {
            do {
                try records.append(decoder.decode(SessionEventRecord.self, from: Data(line)))
            } catch {
                if index == lines.count - 1 {
                    break
                }
                throw SessionStoreError.corrupt("line \(index + 1)")
            }
        }
        return (records, lines.count)
    }

    /// Each non-empty line that ends before `end`, without its newline.
    /// Answers where the last of them ended: what is left after it has no
    /// newline yet.
    @discardableResult
    private static func forEachLine(
        in bytes: UnsafeRawBufferPointer,
        upTo end: Int,
        _ body: (Range<Int>) throws -> Void,
    ) rethrows -> Int {
        guard let base = bytes.baseAddress else { return 0 }
        var start = 0
        while start < end, let found = memchr(base + start, Int32(newline), end - start) {
            let stop = base.distance(to: UnsafeRawPointer(found))
            if stop > start {
                try body(start ..< stop)
            }
            start = stop + 1
        }
        return start
    }

    /// The last non-empty line that ends before `end`, without its newline.
    private static func lastLine(in bytes: UnsafeRawBufferPointer, before end: Int) -> Range<Int>? {
        var stop = end
        while stop > 0, bytes[stop - 1] == newline {
            stop -= 1
        }
        var start = stop
        while start > 0, bytes[start - 1] != newline {
            start -= 1
        }
        return start < stop ? start ..< stop : nil
    }
}
