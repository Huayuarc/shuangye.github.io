import ApelinCore
import Foundation
import XCTest

final class CanonicalPathTests: XCTestCase {
    func testRejectsNUL() {
        XCTAssertTrue(CanonicalPath.containsNUL("/tmp/a\u{0}b"))
        XCTAssertNil(CanonicalPath.resolve("/tmp\u{0}/x"))
    }

    func testComparesComponentsNotPrefixes() {
        XCTAssertTrue(CanonicalPath.isCanonical("/a/b/c", inside: "/a/b"))
        XCTAssertTrue(CanonicalPath.isCanonical("/a/b", inside: "/a/b"))
        XCTAssertFalse(CanonicalPath.isCanonical("/a/bc", inside: "/a/b"))
        XCTAssertFalse(CanonicalPath.isCanonical("/a", inside: "/a/b"))
    }

    func testResolvesSymlinkOut() throws {
        let base = try temporaryDirectory()
        let inside = base.appendingPathComponent("inside")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = inside.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(CanonicalPath.resolved(link.path, isInside: inside.path))
        XCTAssertTrue(CanonicalPath.resolved(inside.path, isInside: base.path))
    }

    func testPlainRelative() {
        XCTAssertTrue(CanonicalPath.isPlainRelative("Sources/Tweak.m"))
        XCTAssertFalse(CanonicalPath.isPlainRelative("../x"))
        XCTAssertFalse(CanonicalPath.isPlainRelative("a/../../x"))
        XCTAssertFalse(CanonicalPath.isPlainRelative("/etc/passwd"))
        XCTAssertFalse(CanonicalPath.isPlainRelative(""))
    }
}

final class ProjectNameTests: XCTestCase {
    func testRules() {
        XCTAssertNil(ProjectName.validate("Hello Tweak"))
        XCTAssertEqual(ProjectName.validate(""), .empty)
        XCTAssertEqual(ProjectName.validate("a/b"), .containsSlash)
        XCTAssertEqual(ProjectName.validate("a\u{0}"), .containsNUL)
        XCTAssertEqual(ProjectName.validate("."), .dotName)
        XCTAssertEqual(ProjectName.validate(".."), .dotName)
        XCTAssertEqual(ProjectName.validate(".hidden"), .leadingDot)
        XCTAssertEqual(ProjectName.validate("a\nb"), .containsControlCharacter)
        XCTAssertEqual(ProjectName.validate(String(repeating: "x", count: 256)), .tooLong)
    }

    func testProjectDirectory() {
        let folder = DataFolder(home: "/var/mobile")
        XCTAssertEqual(folder.root.path, "/var/mobile/Documents/wiki.qaq.apelin")
        XCTAssertEqual(folder.project(named: "Hello")?.path, "/var/mobile/Documents/wiki.qaq.apelin/Projects/Hello")
        XCTAssertNil(folder.project(named: "../x"))
    }

    func testMakeLevels() throws {
        let base = try temporaryDirectory()
        let folder = DataFolder(root: base)
        try folder.makeLevels(to: folder.consoleInbox)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.consoleInbox.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertThrowsError(try folder.makeLevels(to: URL(fileURLWithPath: "/tmp/elsewhere")))
    }

    func testRemoveProjectDoesNotFollowLinks() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = DataFolder(root: base)
        let project = try XCTUnwrap(folder.project(named: "Example"))
        try folder.makeLevels(to: project)
        let outside = base.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link"), withDestinationURL: outside)
        try folder.removeProject(named: "Example")
        try folder.removeProject(named: "Example")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
        XCTAssertEqual(try String(contentsOf: outside), "keep")
        try FileManager.default.createSymbolicLink(at: project, withDestinationURL: base)
        XCTAssertThrowsError(try folder.removeProject(named: "Example"))
        XCTAssertThrowsError(try folder.removeProject(named: "../keep.txt"))
        XCTAssertThrowsError(try folder.removeProject(named: "bad\u{0}name"))
        XCTAssertEqual(try String(contentsOf: outside), "keep")
    }

    func testRemoveProjectRejectsRedirectedProjectsDirectory() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = DataFolder(root: base)
        let other = base.appendingPathComponent("other/Example")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.projects, withDestinationURL: other.deletingLastPathComponent())
        XCTAssertThrowsError(try folder.removeProject(named: "Example"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTripAndPaths() throws {
        let text = #"{"a":{"b":[1,{"c":"x"}]},"n":2.5,"t":true,"z":null}"#
        let value = try JSONCoding.decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(value.value(at: "a.b.1.c"), .string("x"))
        XCTAssertEqual(value.value(at: "a.b.0"), .number(1))
        XCTAssertEqual(value.value(at: "t"), .bool(true))
        XCTAssertEqual(value.value(at: "z"), .null)
        XCTAssertNil(value.value(at: "a.missing"))
        let again = try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(value))
        XCTAssertEqual(again, value)
        XCTAssertEqual(try String(decoding: JSONCoding.encode(JSONValue.number(3)), as: UTF8.self), "3")
    }
}

func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("apelin-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: CanonicalPath.resolve(url.path)!, isDirectory: true)
}
