@testable import ApelinAgent
import Foundation
import Security
import Testing

@Suite("Event log and replay")
struct EventReplayTests {
    @Test
    func `records are numbered, replayed after a sequence number, then live`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        for index in 1 ... 5 {
            try await log.append(.steered(text: "\(index)"))
        }
        #expect(await log.lastSeq == 5)

        let stream = try await log.attach(afterSeq: 3)
        try await log.append(.finished(reason: .completed))
        var received: [SessionEventRecord] = []
        for await record in stream {
            received.append(record)
            if received.count == 3 {
                break
            }
        }
        #expect(received.map(\.seq) == [4, 5, 6])
        #expect(received.last?.event == .finished(reason: .completed))
        await log.close()

        // A new process continues the sequence and replays everything.
        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        #expect(await reopened.lastSeq == 6)
        try await reopened.append(.error(message: "x"))
        #expect(try await reopened.records(afterSeq: 0).map(\.seq) == Array(1 ... 7))
        await reopened.close()

        let file = home.dataRoot.sessions.appendingPathComponent(id).appendingPathComponent("events.jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test
    func `a torn last line is dropped and the next record starts cleanly`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        try await log.append(.textDelta("a"))
        await log.close()
        let file = home.dataRoot.sessions.appendingPathComponent(id).appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\":2,\"da".utf8))
        try handle.close()

        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        #expect(await reopened.lastSeq == 1)
        try await reopened.append(.textDelta("b"))
        #expect(try await reopened.records(afterSeq: 0).map(\.seq) == [1, 2])
        await reopened.close()
    }

    @Test
    func `session ids cannot name a path`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        for bad in ["../x", "abc", "", "\(UUID().uuidString)/.."] {
            #expect(throws: SessionStoreError.self) { _ = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: bad) }
        }
    }

    @Test
    func `the keychain items are this-device-only, unsynchronised, Apelin's own`() {
        let source = KeychainCredentialSource(accessGroup: "TEAMID.wiki.qaq.apelin")
        let query = source.itemQuery(CredentialProviderID.githubCopilot)
        #expect(query[kSecAttrService as String] as? String == "wiki.qaq.apelin.agent")
        #expect(query[kSecAttrAccount as String] as? String == "github-copilot")
        #expect(query[kSecAttrAccessGroup as String] as? String == "TEAMID.wiki.qaq.apelin")
        #expect((query[kSecAttrSynchronizable as String] as? Bool) == false)
        let write = source.writeAttributes(Data())
        #expect(write[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
