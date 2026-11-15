import ApelinCodeSign
import ApelinMachO
import Foundation
import XCTest

/// The signer against the tool it stands in for. `Fixtures/expected` was
/// written by `ldid -Hsha256 -S[entitlements.plist]` from `Fixtures/input`
/// (see `Fixtures/build.sh`); the comparison is the whole file.
final class CodeSignerTests: XCTestCase {
    private func fixture(_ path: String) throws -> URL {
        try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent(path))
    }

    private func assertMatchesLdid(_ name: String, entitled: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let input = try Data(contentsOf: fixture("input/\(name)"))
        let expected = try Data(contentsOf: fixture("expected/\(name)"))
        let entitlements = entitled ? try Data(contentsOf: fixture("entitlements.plist")) : nil
        let signed = try CodeSigner.sign(input, options: .init(identifier: name, entitlements: entitlements))
        XCTAssertEqual(signed.count, expected.count, name, file: file, line: line)
        let difference = zip(signed, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTAssertNil(difference, "\(name): first difference at byte \(difference ?? 0)", file: file, line: line)
    }

    /// Fat, both slices a tweak's: arm64 and arm64e.
    func testFatLibrary() throws {
        try assertMatchesLdid("Fixture.dylib")
    }

    /// One arm64e slice, roothide's.
    func testThinLibrary() throws {
        try assertMatchesLdid("Thin.dylib")
    }

    /// No signature to replace: the load command is added.
    func testLibraryTheLinkerNeverSigned() throws {
        try assertMatchesLdid("Unsigned.dylib")
    }

    func testBundle() throws {
        try assertMatchesLdid("FixtureBundle")
    }

    /// A program with no entitlements: the main-binary flag alone.
    func testProgram() throws {
        try assertMatchesLdid("fixture-tool")
    }

    /// A program with entitlements: the file as written in the XML slot, its
    /// DER, and the executable segment flags they ask for.
    func testProgramWithEntitlements() throws {
        try assertMatchesLdid("fixture-tool-entitled", entitled: true)
    }

    /// An `__info_plist` section hashed into the info slot.
    func testProgramWithInfoPlist() throws {
        try assertMatchesLdid("FixtureApp", entitled: true)
    }

    /// Read back through ApelinMachO rather than through the signer's offsets.
    func testTheResultReadsBack() throws {
        let entitlements = try Data(contentsOf: fixture("entitlements.plist"))
        let signed = try CodeSigner.sign(Data(contentsOf: fixture("input/FixtureApp")), options: .init(identifier: "FixtureApp", entitlements: entitlements))
        let image = try MachOImage(data: signed)
        XCTAssertEqual(image.slices.count, 2)
        for slice in image.slices {
            XCTAssertEqual(try image.entitlementsDictionary(of: slice)?["get-task-allow"] as? Bool, true)
        }
    }

    /// Signing twice gives the same bytes: the old signature is replaced, not
    /// stacked.
    func testSigningIsIdempotent() throws {
        let input = try Data(contentsOf: fixture("input/Fixture.dylib"))
        let once = try CodeSigner.sign(input, options: .init(identifier: "Fixture.dylib"))
        let twice = try CodeSigner.sign(once, options: .init(identifier: "Fixture.dylib"))
        XCTAssertEqual(once, twice)
    }

    func testWhatIsNotCodeIsRefused() throws {
        XCTAssertThrowsError(try CodeSigner.sign(Data("not a binary".utf8), options: .init(identifier: "x"))) {
            XCTAssertEqual($0 as? CodeSignFailure, .notCode)
        }
        var object = try Data(contentsOf: fixture("input/Thin.dylib"))
        object[12] = 1 // MH_OBJECT
        XCTAssertThrowsError(try CodeSigner.sign(object, options: .init(identifier: "x"))) {
            XCTAssertEqual($0 as? CodeSignFailure, .notCode)
        }
        var truncated = try Data(contentsOf: fixture("input/Thin.dylib"))
        truncated = truncated.prefix(40)
        XCTAssertThrowsError(try CodeSigner.sign(truncated, options: .init(identifier: "x")))
    }

    func testEntitlementsLdidWouldNotCarryAreRefused() throws {
        let real = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>x</key><real>1.5</real></dict></plist>
        """.utf8)
        XCTAssertThrowsError(try CodeSigner.sign(Data(contentsOf: fixture("input/fixture-tool")), options: .init(identifier: "t", entitlements: real))) {
            XCTAssertEqual($0 as? CodeSignFailure, .unsupportedEntitlements)
        }
    }

    /// Where ldid and codesign are installed, they read the signature too.
    func testToolsReadTheSignature() throws {
        let ldid = ["/opt/homebrew/bin/ldid", "/usr/local/bin/ldid"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let entitlements = try Data(contentsOf: fixture("entitlements.plist"))
        let signed = try CodeSigner.sign(Data(contentsOf: fixture("input/fixture-tool")), options: .init(identifier: "fixture-tool", entitlements: entitlements))
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("apelin-codesign-\(UUID().uuidString.prefix(8))")
        try signed.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let codesign = try run("/usr/bin/codesign", ["-dv", "--verbose=4", url.path])
        XCTAssertTrue(codesign.contains("Identifier=fixture-tool"), codesign)
        XCTAssertTrue(codesign.contains("Hash type=sha256"), codesign)
        XCTAssertTrue(codesign.contains("CodeDirectory v=20400"), codesign)
        XCTAssertTrue(codesign.contains("Internal requirements count=1"), codesign)
        if let ldid {
            let embedded = try run(ldid, ["-e", url.path])
            XCTAssertTrue(embedded.contains("<key>get-task-allow</key>"), embedded)
        }
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
