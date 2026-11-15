@testable import ApelinDebArchive
import ApelinDebian
import Foundation
import Testing

/// A directory under the system temporary folder, removed when the test ends.
final class Scratch {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApelinDebArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.path
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ name: String, _ contents: String, mode: Int = 0o644) throws -> String {
        let target = path + "/" + name
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
        )
        try Data(contents.utf8).write(to: URL(fileURLWithPath: target))
        chmod(target, mode_t(mode))
        return target
    }
}

/// A tweak-shaped package for both layouts: a dylib, its filter, a tool, a
/// symlink, a long path, maintainer scripts and a conffiles member.
func samplePackage(_ layout: PackageLayout, compression: DebCompression = .zstd) throws -> DebPackageWriter {
    var control = DebianControlFile(
        package: "com.example.sample",
        version: "1.2.3-4",
        architecture: layout.architecture,
        description: "A sample package\nWritten by the tests.",
    )
    control["Maintainer"] = "Example <example@example.com>"
    control["Depends"] = "firmware (>= 16.0)"
    var writer = DebPackageWriter(control: control)
    writer.compression = compression
    writer.modificationTime = 1_760_000_000
    let longName = String(repeating: "deep-directory-name/", count: 8) + "file.txt"
    writer.entries = try [
        .file(layout.tweakLibrary(named: "Sample"), contents: Data(repeating: 0xCF, count: 3000), mode: 0o755),
        .file(layout.tweakFilter(named: "Sample"), contents: Data("{ Filter = { Bundles = ( \"com.apple.springboard\" ); }; }\n".utf8)),
        .file(layout.commandLineTool(named: "sample"), contents: Data("#!/bin/sh\necho sample\n".utf8), mode: 0o755),
        .symbolicLink(layout.packagePath(for: "/usr/bin/sample-link"), target: "sample"),
        .symbolicLink(layout.packagePath(for: "/usr/share/long-link"), target: "/" + longName),
        .file(layout.packagePath(for: "/usr/share/" + longName), contents: Data("long\n".utf8)),
        .file(layout.packagePath(for: "/etc/sample.conf"), contents: Data("key=value\n".utf8)),
        .directory(layout.packagePath(for: "/var/mobile/Empty"), mode: 0o700),
    ]
    writer.maintainerScripts[.postinst] = Data(layout.substitutingPlaceholders(in: "#!/bin/sh\n[ -d @PREFIX@/usr ] || exit 1\nexit 0\n").utf8)
    writer.maintainerScripts[.prerm] = Data("#!/bin/sh\nexit 0\n".utf8)
    writer.controlFiles["conffiles"] = try Data(layout.packagePath(for: "/etc/sample.conf").appending("\n").utf8)
    return writer
}

struct DebPackageWriterTests {
    @Test(arguments: [PackageLayout.rootless, .roothide], DebCompression.allCases)
    func `round trips through the reader`(_ layout: PackageLayout, _ compression: DebCompression) throws {
        let writer = try samplePackage(layout, compression: compression)
        let bytes = try writer.data()
        let contents = try DebArchiveReader.contents(of: .data(bytes), contentsLimit: 1 << 20)

        #expect(contents.members == ["debian-binary", "control.tar" + compression.memberSuffix, "data.tar" + compression.memberSuffix])
        let control = try contents.control()
        #expect(control.package == "com.example.sample")
        #expect(control.version == "1.2.3-4")
        #expect(control.architecture == layout.architecture)
        #expect(try control["Installed-Size"] == String(writer.installedSize()))
        #expect(Set(contents.controlFiles.keys) == ["control", "postinst", "prerm", "conffiles"])
        #expect(contents.controlFiles["postinst"].map { String(decoding: $0, as: UTF8.self) }?
            .contains("[ -d \(layout.installPrefix)/usr ]") == true)

        let byPath = Dictionary(uniqueKeysWithValues: contents.entries.map { ($0.path, $0) })
        for entry in writer.entries {
            let read = try #require(byPath[entry.path], "\(entry.path) is missing")
            switch entry.kind {
            case .directory:
                #expect(read.kind == .directory)
                #expect(read.mode == entry.mode)
            case let .file(.data(data)):
                #expect(read.kind == .file)
                #expect(read.contents == data)
                #expect(read.size == Int64(data.count))
                #expect(read.mode == entry.mode)
            case let .symbolicLink(target):
                #expect(read.kind == .symbolicLink(target: target))
            case .file(.file):
                Issue.record("the sample has no on-disk files")
            }
        }
        // Parents first, every parent present, and nothing else.
        var seen = Set<String>()
        for entry in contents.entries {
            let parent = (entry.path as NSString).deletingLastPathComponent
            #expect(parent == "/" || seen.contains(parent), "\(entry.path) before its parent")
            seen.insert(entry.path)
        }
        if layout == .rootless {
            #expect(contents.directories.prefix(2) == ["/var", "/var/jb"])
            #expect(contents.entries.allSatisfy { $0.path == "/var" || $0.path.hasPrefix("/var/jb") })
        } else {
            #expect(!contents.entries.contains { $0.path.hasPrefix("/var/jb") })
        }
        for entry in contents.entries {
            #expect(entry.userID == 0 && entry.groupID == 0)
            #expect(entry.userName == "root" && entry.groupName == "wheel")
            #expect(entry.modificationTime == 1_760_000_000)
        }
    }

    @Test(arguments: DebCompression.allCases)
    func `is deterministic`(_ compression: DebCompression) throws {
        let first = try samplePackage(.rootless, compression: compression).data()
        var shuffled = try samplePackage(.rootless, compression: compression)
        shuffled.entries.reverse()
        #expect(try shuffled.data() == first)
        #expect(try samplePackage(.rootless, compression: compression).data() == first)
        if compression == .gzip {
            // Two writes in one second would match anyway: the header's
            // MTIME field itself has to be zero.
            for (_, member) in try DebArchiveReaderTests.members(of: first).dropFirst() {
                #expect(member.prefix(2) == Data([0x1F, 0x8B]))
                #expect(member.subdata(in: member.startIndex + 4 ..< member.startIndex + 8) == Data(count: 4))
            }
        }
    }

    @Test func `installed size counts kibibytes`() throws {
        var writer = DebPackageWriter(control: DebianControlFile(
            package: "aa", version: "1", architecture: "all", description: "x",
        ))
        writer.entries = [
            .file("/a/one", contents: Data(count: 1)), // 1, plus /a: 1
            .file("/a/exact", contents: Data(count: 2048)), // 2
            .file("/a/over", contents: Data(count: 2049)), // 3
            .file("/a/empty", contents: Data()), // 0
            .symbolicLink("/a/link", target: "one"), // 1
        ]
        #expect(try writer.installedSize() == 8)
    }

    @Test func `writes files and trees from disk`() throws {
        let scratch = try Scratch()
        let bundle = scratch.path + "/Sample.app"
        _ = try scratch.file("Sample.app/Sample", "binary", mode: 0o755)
        _ = try scratch.file("Sample.app/Info.plist", "plist")
        _ = try scratch.file("Sample.app/Resources/en.lproj/Strings", "strings", mode: 0o600)
        try FileManager.default.createSymbolicLink(atPath: bundle + "/Current", withDestinationPath: "Resources")

        var writer = DebPackageWriter(control: DebianControlFile(
            package: "com.example.app", version: "1.0", architecture: "iphoneos-arm64", description: "x",
        ))
        writer.entries = try DebEntry.tree(fromDirectory: bundle, at: PackageLayout.rootless.applicationBundle(named: "Sample"))
        let output = scratch.path + "/out.deb"
        try writer.write(toPath: output)

        let contents = try DebArchiveReader.contents(of: .path(output), contentsLimit: 1024)
        let byPath = Dictionary(uniqueKeysWithValues: contents.entries.map { ($0.path, $0) })
        let app = "/var/jb/Applications/Sample.app"
        #expect(byPath[app + "/Sample"]?.contents == Data("binary".utf8))
        #expect(byPath[app + "/Sample"]?.mode == 0o755)
        #expect(byPath[app + "/Resources/en.lproj/Strings"]?.mode == 0o600)
        #expect(byPath[app + "/Current"]?.kind == .symbolicLink(target: "Resources"))
        #expect(try DebArchiveReader.control(of: .path(output)).contains("Package: com.example.app"))
        #expect(try DebArchiveReader.controlMembers(of: .path(output)) == ["control"])
        // Nothing left beside the output.
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["Sample.app", "out.deb"])
        var status = stat()
        #expect(lstat(output, &status) == 0 && status.st_mode & 0o777 == 0o644)
    }

    @Test func `refuses invalid descriptions`() throws {
        let control = DebianControlFile(package: "aa", version: "1", architecture: "all", description: "x")
        let invalid: [[DebEntry]] = [
            [.file("/a", contents: Data()), .file("/a", contents: Data())],
            [.file("relative", contents: Data())],
            [.file("/a/../b", contents: Data())],
            [.file("/a", contents: Data()), .file("/a/b", contents: Data())],
            [.symbolicLink("/a", target: "")],
            [DebEntry(path: "/a", kind: .directory, mode: 0o40755)],
            [.file("/", contents: Data())],
        ]
        for entries in invalid {
            var writer = DebPackageWriter(control: control)
            writer.entries = entries
            #expect(throws: PackageFormatError.self, "\(entries)") { try writer.data() }
        }
        var writer = DebPackageWriter(control: control)
        writer.controlFiles["postinst"] = Data()
        #expect(throws: PackageFormatError.self) { try writer.data() }
        writer.controlFiles = ["bad/name": Data()]
        #expect(throws: PackageFormatError.self) { try writer.data() }
    }

    @Test func `failed write leaves nothing behind`() throws {
        let scratch = try Scratch()
        var writer = DebPackageWriter(control: DebianControlFile(
            package: "aa", version: "1", architecture: "all", description: "x",
        ))
        writer.entries = [.file("/missing", copying: scratch.path + "/does-not-exist")]
        let output = scratch.path + "/out.deb"
        try Data("previous".utf8).write(to: URL(fileURLWithPath: output))
        #expect(throws: PackageFormatError.self) { try writer.write(toPath: output) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: output)) == Data("previous".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["out.deb"])
    }

    @Test func `tar header checksum and fields`() {
        let header = TarWriter.header(
            name: Array("./usr/bin/x".utf8), mode: 0o755, size: 10, modificationTime: 0o17,
            typeflag: UInt8(ascii: "0"), linkName: [],
        )
        #expect(header.count == 512)
        #expect(String(decoding: header[100 ..< 107], as: UTF8.self) == "0000755")
        #expect(String(decoding: header[124 ..< 135], as: UTF8.self) == "00000000012")
        #expect(String(decoding: header[257 ..< 265], as: UTF8.self) == "ustar  \0")
        var summed = header
        summed.replaceSubrange(148 ..< 156, with: Array(repeating: 0x20, count: 8))
        let checksum = summed.reduce(0) { $0 + Int($1) }
        #expect(Int(String(decoding: header[148 ..< 154], as: UTF8.self), radix: 8) == checksum)
    }
}

struct DebArchiveReaderTests {
    /// An `ar` archive with the given members, written by hand.
    static func ar(_ members: [(String, Data)]) -> Data {
        var data = Data("!<arch>\n".utf8)
        for (name, contents) in members {
            func field(_ text: String, _ width: Int) -> String {
                text + String(repeating: " ", count: width - text.count)
            }
            let header = field(name, 16) + field("0", 12) + field("0", 6) + field("0", 6) + field("100644", 8)
                + field(String(contents.count), 10) + "`\n"
            data.append(Data(header.utf8))
            data.append(contents)
            if contents.count % 2 == 1 {
                data.append(0x0A)
            }
        }
        return data
    }

    /// The members of a package this writer produced, for rearranging.
    static func members(of package: Data) throws -> [(String, Data)] {
        var members: [(String, Data)] = []
        var offset = 8
        while offset + 60 <= package.count {
            let header = String(decoding: package[offset ..< offset + 60], as: UTF8.self)
            let name = String(header.prefix(16)).trimmingCharacters(in: .whitespaces)
            let size = try #require(Int(header.dropFirst(48).prefix(10).trimmingCharacters(in: .whitespaces)))
            members.append((name, package.subdata(in: offset + 60 ..< offset + 60 + size)))
            offset += 60 + size + size % 2
        }
        return members
    }

    @Test func `refuses what is not A package`() throws {
        let package = try samplePackage(.roothide, compression: .gzip).data()
        let members = try Self.members(of: package)
        #expect(members.map(\.0) == ["debian-binary", "control.tar.gz", "data.tar.gz"])
        let broken: [Data] = [
            Data("not an archive at all".utf8),
            Self.ar([members[1], members[0], members[2]]), // debian-binary not first
            Self.ar([("debian-binary", Data("3.0\n".utf8)), members[1], members[2]]),
            Self.ar([members[0], members[2], members[1]]), // data before control
            Self.ar([members[0], members[1]]), // no data
            Self.ar([members[0], members[1], members[1], members[2]]), // control twice
            Self.ar([members[0], members[1], ("data.tar.gz", members[2].1.prefix(40))]), // truncated
        ]
        for data in broken {
            #expect(throws: PackageFormatError.self) { try DebArchiveReader.contents(of: .data(data)) }
        }
        // An unknown member after data is skipped, as dpkg does.
        let extended = Self.ar(members + [("_extra", Data("x".utf8))])
        #expect(try DebArchiveReader.contents(of: .data(extended)).members.last == "_extra")
    }

    /// Corrupted packages throw or read; none traps.
    @Test(arguments: [DebCompression.none, .zstd])
    func `corrupted bytes never trap`(_ compression: DebCompression) throws {
        let original = try samplePackage(.rootless, compression: compression).data()
        var state: UInt64 = 0x5EED
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        for _ in 0 ..< 600 {
            var data = original
            for _ in 0 ..< 1 + Int(next() % 4) {
                data[Int(next() % UInt64(data.count))] = UInt8(truncatingIfNeeded: next())
            }
            _ = try? DebArchiveReader.contents(of: .data(data), contentsLimit: 4096)
            _ = try? DebArchiveReader.control(of: .data(data))
        }
    }

    @Test func `entry limit`() throws {
        let package = try samplePackage(.rootless).data()
        #expect(throws: PackageFormatError.self) {
            try DebArchiveReader.contents(of: .data(package), maximumEntryCount: 3)
        }
    }

    @Test func `decompresses any filter`() throws {
        let package = try samplePackage(.rootless, compression: .xz).data()
        let members = try Self.members(of: package)
        let tar = try DebArchiveReader.decompress(members[2].1)
        #expect(tar.count % 512 == 0)
        #expect(String(decoding: tar[257 ..< 263], as: UTF8.self) == "ustar ")
        #expect(try DebArchiveReader.decompress(Data("plain".utf8)) == Data("plain".utf8))
    }
}
