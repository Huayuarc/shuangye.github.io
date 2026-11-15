import ApelinDebian
import Foundation
import Testing

struct DebianControlFileTests {
    @Test func `renders in order with folded description`() throws {
        var control = DebianControlFile(
            package: "com.example.tool",
            version: "1.0-1",
            architecture: "iphoneos-arm64",
            description: "An example tool\nIt does one thing.\n\n  verbatim line",
        )
        control["Maintainer"] = "Example <example@example.com>"
        control["Depends"] = "firmware (>= 16.0)"
        control["Installed-Size"] = "12"
        #expect(try control.rendered() == """
        Package: com.example.tool
        Version: 1.0-1
        Architecture: iphoneos-arm64
        Description: An example tool
         It does one thing.
         .
           verbatim line
        Maintainer: Example <example@example.com>
        Depends: firmware (>= 16.0)
        Installed-Size: 12

        """)
    }

    @Test func `subscript ignores case and keeps position`() throws {
        var control = DebianControlFile(package: "aa", version: "1", architecture: "all", description: "x")
        control["version"] = "2"
        #expect(control.fields.map(\.name) == ["Package", "Version", "Architecture", "Description"])
        #expect(control["VERSION"] == "2")
        control["Architecture"] = nil
        #expect(control.architecture == nil)
        #expect(throws: PackageFormatError.self) { try control.rendered() }
    }

    @Test func `parses A template and round trips`() throws {
        let template = """
        Package: wiki.qaq.apelin
        Name: Apelin
        Version: 1.0
        Architecture: iphoneos-arm64e
        Description: An on-device IDE
         Apelin is an on-device IDE.
         .
         Second paragraph.
        Depends: firmware (>= 16.0), uikittools, launchctl

        """
        let control = try DebianControlFile(parsing: template)
        #expect(control.fields.map(\.name) == ["Package", "Name", "Version", "Architecture", "Description", "Depends"])
        #expect(control["description"] == "An on-device IDE\nApelin is an on-device IDE.\n\nSecond paragraph.")
        #expect(try control.rendered() == template)
        let reparsed = try DebianControl.parse(control.rendered())
        #expect(reparsed["depends"] == "firmware (>= 16.0), uikittools, launchctl")
    }

    @Test(arguments: [
        ("Package", "A.upper"), ("Package", "a"), ("Package", "-dash"), ("Package", "has space"),
        ("Version", "1.0-"), ("Version", ""), ("Version", "1 0"),
        ("Architecture", "two words"),
        ("Description", "\nno synopsis"),
        ("Depends", "a\rb"), ("Depends", "a\u{0}b"), ("Depends", ""),
    ])
    func `refuses what dpkg would not read`(_ field: String, _ value: String) {
        var control = DebianControlFile(package: "com.example", version: "1.0", architecture: "all", description: "x")
        control[field] = value
        #expect(throws: PackageFormatError.self) { try control.rendered() }
    }

    @Test(arguments: ["", "#Comment", "-Dash", "Has:Colon", "Has Space"])
    func `refuses bad field names`(_ name: String) {
        var control = DebianControlFile(package: "com.example", version: "1.0", architecture: "all", description: "x")
        control[name] = "value"
        #expect(throws: PackageFormatError.self) { try control.rendered() }
    }

    @Test func `multiline field with empty first line`() throws {
        var control = DebianControlFile(package: "com.example", version: "1.0", architecture: "all", description: "x")
        control["Conffiles"] = "\n/etc/example.conf 0123"
        let text = try control.rendered()
        #expect(text.hasSuffix("Conffiles:\n /etc/example.conf 0123\n"))
        #expect(try DebianControlFile(parsing: text)["Conffiles"] == "\n/etc/example.conf 0123")
    }
}

struct PackageLayoutTests {
    @Test func `flavor table matches the packager`() {
        // Scripts/package-deb.sh: rootless:iphoneos-arm64:/var/jb | roothide:iphoneos-arm64e:
        #expect(PackageLayout.rootless.installPrefix == "/var/jb")
        #expect(PackageLayout.rootless.architecture == "iphoneos-arm64")
        #expect(PackageLayout.rootless.rootfsPrefix == "")
        #expect(PackageLayout.roothide.installPrefix == "")
        #expect(PackageLayout.roothide.architecture == "iphoneos-arm64e")
        #expect(PackageLayout.roothide.rootfsPrefix == "/rootfs")
        #expect(PackageLayout(architecture: "iphoneos-arm64") == .rootless)
        #expect(PackageLayout(architecture: "iphoneos-arm64e") == .roothide)
        #expect(PackageLayout(architecture: "iphoneos-arm") == nil)
    }

    @Test func `product paths`() throws {
        let rootless = PackageLayout.rootless
        let roothide = PackageLayout.roothide
        #expect(try rootless.applicationBundle(named: "Example") == "/var/jb/Applications/Example.app")
        #expect(try roothide.applicationBundle(named: "Example.app") == "/Applications/Example.app")
        #expect(try rootless.tweakLibrary(named: "Hook")
            == "/var/jb/Library/MobileSubstrate/DynamicLibraries/Hook.dylib")
        #expect(try rootless.tweakFilter(named: "Hook")
            == "/var/jb/Library/MobileSubstrate/DynamicLibraries/Hook.plist")
        #expect(try roothide.tweakLibrary(named: "Hook") == "/Library/MobileSubstrate/DynamicLibraries/Hook.dylib")
        #expect(try rootless.commandLineTool(named: "tool") == "/var/jb/usr/bin/tool")
        #expect(try roothide.commandLineTool(named: "tool") == "/usr/bin/tool")
        #expect(try rootless.preferenceBundle(named: "Prefs") == "/var/jb/Library/PreferenceBundles/Prefs.bundle")
        #expect(try roothide.preferenceLoaderEntry(named: "Prefs")
            == "/Library/PreferenceLoader/Preferences/Prefs.plist")
    }

    @Test func `logical and package paths invert`() throws {
        for layout in [PackageLayout.rootless, .roothide] {
            for logical in ["/", "/usr/bin/tool", "/Applications/X.app/X"] {
                let packaged = try layout.packagePath(for: logical)
                #expect(try layout.logicalPath(forPackagePath: packaged) == logical)
            }
        }
        #expect(try PackageLayout.rootless.packagePath(for: "/") == "/var/jb")
        #expect(throws: PackageFormatError.self) { try PackageLayout.rootless.logicalPath(forPackagePath: "/usr/bin/x") }
    }

    @Test(arguments: [
        "usr/bin/x", "/usr//bin", "/usr/bin/", "/usr/./bin", "/usr/../etc", "/var/jb/usr/bin/x",
        "/rootfs/usr/lib", "/a\u{0}b", "/a\nb", "",
    ])
    func `refuses non canonical logical paths`(_ path: String) {
        #expect(throws: PackageFormatError.self) { try PackageLayout.rootless.packagePath(for: path) }
        #expect(throws: PackageFormatError.self) { try PackageLayout.roothide.packagePath(for: path) }
    }

    @Test(arguments: ["", ".", "..", "a/b", ".app", "a\u{0}"])
    func `refuses bad names`(_ name: String) {
        #expect(throws: PackageFormatError.self) { try PackageLayout.rootless.applicationBundle(named: name) }
    }

    @Test func placeholders() {
        let plist = "<string>@PREFIX@/usr/libexec/apelind</string><string>@ROOTFS@/usr/lib</string>"
        #expect(PackageLayout.rootless.substitutingPlaceholders(in: plist)
            == "<string>/var/jb/usr/libexec/apelind</string><string>/usr/lib</string>")
        #expect(PackageLayout.roothide.substitutingPlaceholders(in: plist)
            == "<string>/usr/libexec/apelind</string><string>/rootfs/usr/lib</string>")
    }

    @Test func `relative member names`() throws {
        #expect(try PackagePath.relative("./") == "")
        #expect(try PackagePath.relative("./usr/bin/") == "usr/bin")
        #expect(try PackagePath.relative("usr/./bin/x") == "usr/bin/x")
        #expect(throws: PackageFormatError.self) { try PackagePath.relative("/etc/passwd") }
        #expect(throws: PackageFormatError.self) { try PackagePath.relative("./usr/../../etc") }
    }
}
