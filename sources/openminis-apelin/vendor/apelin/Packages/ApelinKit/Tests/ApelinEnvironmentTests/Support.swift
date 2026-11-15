import ApelinCore
@testable import ApelinEnvironment
import ArchiveKit
import Foundation
import XCTest

/// A home folder of its own per test, with the data folder made the way the
/// package's postinst makes it.
struct TemporaryHome {
    let home: URL
    let layout: EnvironmentLayout

    init(_ test: XCTestCase) throws {
        // realpath: on macOS the temporary folder is behind /var → /private/var.
        let base = URL(fileURLWithPath: CanonicalPath.resolve(NSTemporaryDirectory())!, isDirectory: true)
        home = base.appendingPathComponent("apelin-env-\(UUID().uuidString)", isDirectory: true)
        let data = DataFolder(home: home.path)
        try FileManager.default.createDirectory(at: data.root, withIntermediateDirectories: true)
        layout = EnvironmentLayout(data: data, installRoot: home.appendingPathComponent("jbroot").path, home: home.path)
        let home = home
        test.addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    }

    var inbox: URL {
        try? layout.make(layout.inbox)
        return layout.inbox
    }
}

/// Mach-O headers with no load commands: enough for the type check, and no
/// binary checked into the repository.
enum MachOFixture {
    static let arm64: UInt32 = 0x0100_000C
    static let x86_64: UInt32 = 0x0100_0007

    static func thin(fileType: UInt32, cpu: UInt32 = arm64) -> Data {
        var data = Data()
        for word: UInt32 in [0xFEED_FACF, cpu, 0, fileType, 0, 0, 0, 0] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A fat file over `slices`, each at a 64-byte boundary.
    static func fat(_ slices: [(cpu: UInt32, data: Data)]) -> Data {
        var data = Data()
        func big(_ word: UInt32) {
            withUnsafeBytes(of: word.bigEndian) { data.append(contentsOf: $0) }
        }
        big(0xCAFE_BABE)
        big(UInt32(slices.count))
        var offset = 64 * ((8 + 20 * slices.count) / 64 + 1)
        var layout: [(Int, Data)] = []
        for slice in slices {
            big(slice.cpu); big(0); big(UInt32(offset)); big(UInt32(slice.data.count)); big(6)
            layout.append((offset, slice.data))
            offset += 64 * (slice.data.count / 64 + 1)
        }
        for (start, bytes) in layout {
            data.append(Data(count: start - data.count))
            data.append(bytes)
        }
        return data
    }

    /// A BSD `ar` archive with each member under its name.
    static func archive(_ members: [(name: String, data: Data)]) -> Data {
        var data = Data("!<arch>\n".utf8)
        for member in members {
            func field(_ text: String, _ width: Int) -> Data {
                Data(text.utf8) + Data(repeating: 0x20, count: width - text.utf8.count)
            }
            data += field(member.name, 16) + field("0", 12) + field("0", 6) + field("0", 6) + field("644", 8)
            data += field(String(member.data.count), 10) + Data([0x60, 0x0A])
            data += member.data
            if member.data.count % 2 == 1 {
                data.append(0x0A)
            }
        }
        return data
    }

    static let dylib = thin(fileType: 6)
    static let object = thin(fileType: 1)
    static let executable = thin(fileType: 2)
    static let bundle = thin(fileType: 8)
}

/// A tiny SDK: SDKSettings.json, Foundation.tbd, a dylib, a static archive
/// of an object, a Swift interface, a header.
enum SDKFixture {
    @discardableResult
    static func make(at url: URL, canonicalName: String = "iphoneos99.0", version: String = "99.0") throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        let settings = #"{"CanonicalName": "\#(canonicalName)", "Version": "\#(version)", "DisplayName": "iOS \#(version)"}"#
        try Data(settings.utf8).write(to: url.appendingPathComponent("SDKSettings.json"))
        let foundation = url.appendingPathComponent("System/Library/Frameworks/Foundation.framework")
        try manager.createDirectory(at: foundation.appendingPathComponent("Headers"), withIntermediateDirectories: true)
        let tbd = """
        --- !tapi-tbd
        tbd-version:     4
        targets:         [ arm64e-ios,
                           arm64e.x1-ios ]
        install-name:    '/System/Library/Frameworks/Foundation.framework/Foundation'
        ...
        """
        try Data(tbd.utf8).write(to: foundation.appendingPathComponent("Foundation.tbd"))
        try Data("// Foundation\n".utf8).write(to: foundation.appendingPathComponent("Headers/Foundation.h"))
        let lib = url.appendingPathComponent("usr/lib")
        try manager.createDirectory(at: lib, withIntermediateDirectories: true)
        try MachOFixture.dylib.write(to: lib.appendingPathComponent("libfixture.dylib"))
        try MachOFixture.archive([("fixture.o", MachOFixture.object)]).write(to: lib.appendingPathComponent("libfixture.a"))
        let swift = lib.appendingPathComponent("swift/Swift.swiftmodule")
        try manager.createDirectory(at: swift, withIntermediateDirectories: true)
        let interface = "// swift-interface-format-version: 1.0\n// swift-compiler-version: Apple Swift version 9.9 (fixture)\n"
        try Data(interface.utf8).write(to: swift.appendingPathComponent("arm64e-apple-ios.swiftinterface"))
        // A link that stays inside.
        try manager.createSymbolicLink(atPath: lib.appendingPathComponent("libfixture.1.dylib").path, withDestinationPath: "libfixture.dylib")
        return url
    }
}

/// Writes archives with libarchive, so the import tests need no tool.
enum ArchiveFixture {
    enum Kind { case tarXZ, tarZstd, zip }

    struct Entry {
        var name: String
        var data: Data?
        var symlink: String?
        var directory = false
        var mode: Int32 = 0o644
    }

    /// Every file and folder under `folder`, named from `prefix`.
    static func entries(of folder: URL, prefix: String) throws -> [Entry] {
        var entries: [Entry] = [Entry(name: prefix, directory: true)]
        let enumerator = FileManager.default.enumerator(atPath: folder.path)!
        while let relative = enumerator.nextObject() as? String {
            let path = folder.appendingPathComponent(relative).path
            let name = prefix + "/" + relative
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?: entries.append(Entry(name: name, directory: true))
            case .typeSymbolicLink?: try entries.append(Entry(name: name, symlink: FileManager.default.destinationOfSymbolicLink(atPath: path)))
            default: entries.append(Entry(name: name, data: FileManager.default.contents(atPath: path)))
            }
        }
        return entries
    }

    static func write(_ entries: [Entry], kind: Kind, to url: URL) throws {
        let archive = archive_write_new()!
        defer { archive_write_free(archive) }
        switch kind {
        case .tarXZ:
            archive_write_set_format_pax_restricted(archive)
            archive_write_add_filter_xz(archive)
        case .tarZstd:
            archive_write_set_format_pax_restricted(archive)
            archive_write_add_filter_zstd(archive)
        case .zip:
            archive_write_set_format_zip(archive)
        }
        guard archive_write_open_filename(archive, url.path) == ARCHIVE_OK else {
            throw NSError(domain: "ArchiveFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: archive_error_string(archive))])
        }
        for item in entries {
            let entry = archive_entry_new()!
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, item.name)
            if item.directory {
                archive_entry_set_filetype(entry, UInt32(S_IFDIR))
                archive_entry_set_perm(entry, 0o755)
            } else if let target = item.symlink {
                archive_entry_set_filetype(entry, UInt32(S_IFLNK))
                archive_entry_set_symlink(entry, target)
                archive_entry_set_perm(entry, 0o755)
            } else {
                archive_entry_set_filetype(entry, UInt32(S_IFREG))
                archive_entry_set_perm(entry, mode_t(item.mode))
                archive_entry_set_size(entry, Int64(item.data?.count ?? 0))
            }
            archive_write_header(archive, entry)
            if let data = item.data, !data.isEmpty {
                _ = data.withUnsafeBytes { archive_write_data(archive, $0.baseAddress, $0.count) }
            }
        }
        archive_write_close(archive)
    }
}

/// Collects a task's events.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(String, JSONValue?)] = []

    var events: [(String, JSONValue?)] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var kinds: [String] {
        events.map(\.0)
    }

    func append(_ kind: String, _ payload: JSONValue?) {
        lock.lock(); defer { lock.unlock() }
        stored.append((kind, payload))
    }

    func last(_ kind: String) -> JSONValue? {
        events.last { $0.0 == kind }?.1
    }

    var reporter: TaskReporter {
        TaskReporter { [self] kind, payload in append(kind, payload) }
    }
}
