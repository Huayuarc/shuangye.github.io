@testable import ApelinDebArchive
import ApelinDebian
import Foundation
import Testing

/// The packages this module writes, judged by dpkg's own tool, and a package
/// dpkg-deb built, read by this module's reader. Skipped where `dpkg-deb` is
/// not installed; `make check` needs it on the Mac anyway.
struct DpkgDebTests {
    static let dpkgDeb: String? = ["/opt/homebrew/bin/dpkg-deb", "/usr/local/bin/dpkg-deb", "/usr/bin/dpkg-deb"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = try URL(fileURLWithPath: #require(dpkgDeb))
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "dpkg-deb \(arguments.joined(separator: " ")): \(errorText)")
        return String(decoding: data, as: UTF8.self)
    }

    @Test(.enabled(if: dpkgDeb != nil), arguments: [PackageLayout.rootless, .roothide], DebCompression.allCases)
    func `dpkg deb accepts what we write`(_ layout: PackageLayout, _ compression: DebCompression) throws {
        let scratch = try Scratch()
        let writer = try samplePackage(layout, compression: compression)
        let deb = scratch.path + "/sample.deb"
        try writer.write(toPath: deb)

        let info = try Self.run(["-I", deb])
        #expect(info.contains("new Debian package, version 2.0."))
        #expect(info.contains(" Package: com.example.sample"))
        #expect(info.contains(" Architecture: \(layout.architecture)"))
        #expect(try info.contains(" Installed-Size: \(writer.installedSize())"))
        #expect(info.contains("postinst"))
        #expect(try Self.run(["-f", deb, "Version"]) == "1.2.3-4\n")

        let listing = try Self.run(["-c", deb])
        let lines = listing.split(separator: "\n")
        #expect(lines.allSatisfy { $0.contains(" root/wheel ") })
        let prefix = "." + layout.installPrefix
        #expect(lines.contains {
            $0.hasPrefix("-rwxr-xr-x root/wheel ") && $0.contains(" 3000 ")
                && $0.hasSuffix("\(prefix)/Library/MobileSubstrate/DynamicLibraries/Sample.dylib")
        })
        #expect(listing.contains("\(prefix)/usr/bin/sample-link -> sample"))
        #expect(listing.contains("drwx------ root/wheel"))
        #expect(lines.first?.hasSuffix(" ./") == true)

        // Unpacked by dpkg-deb itself: contents, links and modes as described.
        let root = scratch.path + "/root"
        try Self.run(["-x", deb, root])
        let tool = try String(contentsOfFile: root + layout.commandLineTool(named: "sample"), encoding: .utf8)
        #expect(tool == "#!/bin/sh\necho sample\n")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: root + layout.packagePath(for: "/usr/bin/sample-link"))
        #expect(link == "sample")
        var status = stat()
        let library = try root + layout.tweakLibrary(named: "Sample")
        #expect(lstat(library, &status) == 0)
        #expect(status.st_mode & 0o7777 == 0o755)
        let longFile = try root + layout.packagePath(for: "/usr/share/" + String(repeating: "deep-directory-name/", count: 8) + "file.txt")
        #expect(try String(contentsOfFile: longFile, encoding: .utf8) == "long\n")

        let control = scratch.path + "/control"
        try Self.run(["-e", deb, control])
        #expect(lstat(control + "/postinst", &status) == 0 && status.st_mode & 0o777 == 0o755)
        let conffile = try layout.packagePath(for: "/etc/sample.conf") + "\n"
        #expect(try String(contentsOfFile: control + "/conffiles", encoding: .utf8) == conffile)
    }

    @Test(.enabled(if: dpkgDeb != nil), arguments: DebCompression.allCases)
    func `reader reads what dpkg deb writes`(_ compression: DebCompression) throws {
        let scratch = try Scratch()
        let tree = scratch.path + "/tree"
        _ = try scratch.file("tree/DEBIAN/control", """
        Package: com.example.dpkg
        Version: 2:0.9~beta1
        Architecture: iphoneos-arm64
        Maintainer: Example <example@example.com>
        Description: Built by dpkg-deb

        """)
        _ = try scratch.file("tree/DEBIAN/postinst", "#!/bin/sh\nexit 0\n", mode: 0o755)
        _ = try scratch.file("tree/var/jb/usr/bin/tool", "tool\n", mode: 0o755)
        try FileManager.default.createSymbolicLink(atPath: tree + "/var/jb/usr/bin/alias", withDestinationPath: "tool")
        let deb = scratch.path + "/dpkg.deb"
        let flag = switch compression {
        case .zstd: "-Zzstd"
        case .xz: "-Zxz"
        case .gzip: "-Zgzip"
        case .none: "-Znone"
        }
        try Self.run(["--root-owner-group", flag, "-b", tree, deb])

        let contents = try DebArchiveReader.contents(of: .path(deb), contentsLimit: 64)
        let control = try contents.control()
        #expect(control.package == "com.example.dpkg")
        #expect(control.version.flatMap(DebianVersion.canonical) == "2:0.9~beta1")
        #expect(Set(contents.controlFiles.keys) == ["control", "postinst"])
        let byPath = Dictionary(uniqueKeysWithValues: contents.entries.map { ($0.path, $0) })
        #expect(byPath["/var/jb/usr/bin/tool"]?.contents == Data("tool\n".utf8))
        #expect(byPath["/var/jb/usr/bin/tool"]?.mode == 0o755)
        #expect(byPath["/var/jb/usr/bin/alias"]?.kind == .symbolicLink(target: "tool"))
        #expect(byPath["/var/jb/usr/bin"]?.kind == .directory)
        #expect(contents.entries.allSatisfy { $0.userID == 0 && $0.groupID == 0 })
    }
}
