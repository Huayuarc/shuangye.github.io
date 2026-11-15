import ApelinCore
import Foundation
import XCTest

final class MemoryStoreTests: XCTestCase {
    func testCRUDPersistsAcrossInstancesAndFiltersProjects() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(root: root)
        let global = MemoryRecord(title: "Language", body: "Use Chinese.")
        let project = MemoryRecord(title: "Target", body: "Support iOS 16.", projectID: "first")
        var snapshot = try store.save(global, revision: store.read().revision)
        snapshot = try store.save(project, revision: snapshot.revision)
        XCTAssertEqual(try MemoryStore(root: root).read(), snapshot)
        XCTAssertEqual(snapshot.forProject("first").records, [global, project])
        XCTAssertEqual(snapshot.forProject("other").records, [global])
        let edited = MemoryRecord(id: global.id, title: "Language", body: "Use English.")
        snapshot = try store.save(edited, replacing: global.id, revision: snapshot.revision)
        XCTAssertEqual(snapshot.records.first, edited)
        snapshot = try store.delete(id: global.id, revision: snapshot.revision)
        XCTAssertEqual(snapshot.records, [project])
    }

    func testStaleCreationOrUpdateCannotUndoUserDeletion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(root: root)
        let record = MemoryRecord(title: "Preference", body: "Short replies.")
        let before = try store.save(record, revision: store.read().revision)
        let after = try MemoryStore(root: root).delete(id: record.id, revision: before.revision)
        XCTAssertThrowsError(try store.save(record, replacing: record.id, revision: before.revision)) { XCTAssertEqual($0 as? MemoryStoreError, .changed) }
        XCTAssertThrowsError(try store.save(MemoryRecord(title: record.title, body: record.body), revision: before.revision)) { XCTAssertEqual($0 as? MemoryStoreError, .changed) }
        XCTAssertEqual(try store.read(), after)
        XCTAssertTrue(after.records.isEmpty)
    }

    func testConcurrentWritersNeverLoseAnAcceptedUpdate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = try MemoryStore(root: root).read().revision
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 12 {
                group.addTask {
                    do {
                        try MemoryStore(root: root).save(MemoryRecord(title: "Writer \(index)", body: "Saved"), revision: revision)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await saved in group where saved {
                count += 1
            }
            return count
        }
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(try MemoryStore(root: root).read().records.count, 1)
    }

    func testRejectsUnsafeFilesAndKeepsCorruptData() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json")
        let file = root.appendingPathComponent("memories.json")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let store = MemoryStore(root: root)
        XCTAssertThrowsError(try store.read())
        XCTAssertEqual(try String(contentsOf: outside), "secret")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: outside, to: file)
        XCTAssertThrowsError(try store.read())
        try FileManager.default.removeItem(at: file)
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try store.read())
        XCTAssertThrowsError(try store.save(MemoryRecord(title: "New", body: "Text"), revision: "empty"))
        XCTAssertEqual(try String(contentsOf: file), "broken")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: root.appendingPathComponent("memories.lock"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("memories.lock"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.read())
    }

    func testLongMemoryPersistsWithoutPerRecordCharacterLimits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(root: root)
        let record = MemoryRecord(title: String(repeating: "标题", count: 100), body: String(repeating: "正文", count: 1500))
        let saved = try store.save(record, revision: store.read().revision)
        XCTAssertEqual(try MemoryStore(root: root).read(), saved)
        XCTAssertEqual(saved.records, [record])
        let oversized = MemoryRecord(id: record.id, title: "Large", body: String(repeating: "x", count: MemoryStore.maximumContentBytes))
        XCTAssertThrowsError(try store.save(oversized, replacing: record.id, revision: saved.revision)) {
            XCTAssertEqual($0 as? MemoryStoreError, .full)
        }
        XCTAssertEqual(try store.read(), saved)
    }

    func testBoundsAreAtomicAndScopeCannotBeChangedByUpdate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(root: root)
        var snapshot = try store.read()
        XCTAssertThrowsError(try store.save(MemoryRecord(title: " ", body: "text"), revision: snapshot.revision))
        XCTAssertThrowsError(try store.save(MemoryRecord(title: "Two\nlines", body: "text"), revision: snapshot.revision))
        let scoped = MemoryRecord(title: "Target", body: "iPhone", projectID: "project")
        snapshot = try store.save(scoped, revision: snapshot.revision)
        XCTAssertThrowsError(try store.save(MemoryRecord(id: scoped.id, title: scoped.title, body: scoped.body), replacing: scoped.id, revision: snapshot.revision))
        for index in 0 ..< 16 {
            snapshot = try store.save(MemoryRecord(title: "Note \(index)", body: String(repeating: "x", count: 1950)), revision: snapshot.revision)
        }
        XCTAssertThrowsError(try store.save(MemoryRecord(title: "Too much", body: String(repeating: "x", count: 2000)), revision: snapshot.revision)) { XCTAssertEqual($0 as? MemoryStoreError, .full) }
        XCTAssertEqual(try store.read(), snapshot)
    }
}
