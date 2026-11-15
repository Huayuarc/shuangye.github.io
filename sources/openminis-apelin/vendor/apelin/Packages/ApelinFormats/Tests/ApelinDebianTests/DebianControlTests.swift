// Copied from Irisin (MIT, OwnGoal Studio):
// Packages/AptRepository/Tests/AptRepositoryTests/DebianControlTests.swift.

import ApelinDebian
import Testing

struct DebianControlTests {
    @Test func `continuation and literal hash`() throws {
        let fields = try DebianControl.parse("Package: aa\nDepends: bb,\n\tcc\nDescription: text # is literal\nConffiles:\n /etc/aa digest\n")
        #expect(fields["depends"] == "bb, cc")
        #expect(fields["description"] == "text # is literal")
        #expect(fields["conffiles"] == " /etc/aa digest")
    }

    @Test(arguments: ["Package: aa\nDepends: bb\nDepends: cc", " depends on nothing", "Package: aa\ninvalid", "Package: aa\nDepends: bb\0cc"])
    func `malformed paragraph is rejected`(_ value: String) {
        #expect(throws: (any Error).self) { try DebianControl.parse(value) }
    }
}
