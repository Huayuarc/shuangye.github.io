import ApelinToolHost
import Darwin
import Foundation
import MachOReader
import XCTest

/// The two extensions end to end on the Mac: spawned through
/// `ToolHostClient`, as the session host will, against binaries on this
/// machine and one assembled here.
final class ExtensionTests: XCTestCase {
    static let productsDirectory = Bundle(for: ExtensionTests.self).bundleURL.deletingLastPathComponent()
    static let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func manifest(_ name: String) throws -> ToolManifest {
        let url = Self.packageDirectory.appendingPathComponent("Packaging/\(name)/manifest.json")
        return try JSONDecoder().decode(ToolManifest.self, from: Data(contentsOf: url))
    }

    private func client(_ executable: String, manifest: ToolManifest) async throws -> ToolHostClient {
        let client = ToolHostClient(configuration: .init(executable: Self.productsDirectory.appendingPathComponent(executable).path,
                                                         limits: ToolProtocolLimits(maxAttachmentBytes: 1 << 30),
                                                         manifest: manifest))
        let hello = try await client.start()
        XCTAssertEqual(hello.peer.name, manifest.id)
        XCTAssertEqual(hello.peer.version, manifest.version)
        return client
    }

    /// The shipped manifest is the code's own description, field for field.
    func testManifestsMatchTheExecutables() throws {
        for (executable, name) in [("apelin-disassembler", "disassembler"), ("apelin-assembler", "assembler")] {
            let process = Process()
            process.executableURL = Self.productsDirectory.appendingPathComponent(executable)
            process.arguments = ["--describe"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let described = try JSONDecoder().decode(JSONValue.self, from: data)
            let shipped = try manifest(name)
            XCTAssertEqual(described["id"]?.stringValue, shipped.id)
            XCTAssertEqual(described["version"]?.stringValue, shipped.version)
            let tools = try JSONDecoder().decode([ToolDescriptor].self, from: JSONEncoder().encode(described["tools"]))
            XCTAssertEqual(tools, shipped.tools, "\(name): Packaging/\(name)/manifest.json has drifted from the code")
            XCTAssertEqual(shipped.executable, "usr/libexec/apelin/agent-tools/\(executable)")
        }
    }

    func testMachOReaderReadsThisMachine() throws {
        let image = try MachOFile(MappedFile(path: "/bin/ls"))
        XCTAssertFalse(image.slices.isEmpty)
        let slice = try image.slice(arch: "arm64e")
        XCTAssertFalse(slice.segments.isEmpty)
        XCTAssertTrue(slice.sections.contains { $0.segment == "__TEXT" && $0.name == "__text" })
        XCTAssertThrowsError(try MachOFile(MappedFile(path: "/etc/hosts")))
    }

    func testDisassembleAndSymbols() async throws {
        // A binary with symbols: the test bundle's own executable.
        let binary = Self.productsDirectory.appendingPathComponent("apelin-disassembler").path
        let client = try await client("apelin-disassembler", manifest: manifest("disassembler"))

        let symbols = await client.call(tool: "symbols", arguments: ["binary": .string(binary), "filter": "main", "kind": "defined"])
        guard let listing = symbols.result?.text else { return XCTFail("\(String(describing: symbols.failure))") }
        XCTAssertTrue(listing.contains(" T _main"), listing)

        let disassembly = await client.call(tool: "disassemble", arguments: ["binary": .string(binary), "address": "_main", "count": 8])
        guard let text = disassembly.result?.text else { return XCTFail("\(String(describing: disassembly.failure))") }
        XCTAssertTrue(text.contains("_main:"), text)
        XCTAssertEqual(text.split(separator: "\n").filter { $0.hasPrefix("0x") }.count, 8, text)

        let imports = await client.call(tool: "symbols", arguments: ["binary": .string(binary), "kind": "undefined", "limit": 5])
        XCTAssertTrue(imports.result?.text.contains(" U _") == true, "\(String(describing: imports.result?.text))")

        let missing = await client.call(tool: "disassemble", arguments: ["binary": "/nonexistent", "address": "0x0"])
        XCTAssertEqual(missing.failure?.code, .toolFailed)
        let badArgs = await client.call(tool: "disassemble", arguments: ["binary": .string(binary)])
        XCTAssertEqual(badArgs.failure?.code, .invalidArguments, "address is required")
        let notSymbol = await client.call(tool: "disassemble", arguments: ["binary": .string(binary), "address": "_noSuchSymbol"])
        XCTAssertEqual(notSymbol.failure?.code, .invalidArguments)

        // The host can hand over the binary as a descriptor instead.
        let attachment = try ToolOutgoingAttachment(path: binary, argument: "binary", mimeType: "application/x-mach-binary")
        let viaDescriptor = await client.call(tool: "symbols", arguments: ["binary": "attached", "filter": "main", "kind": "defined"],
                                              attachments: [attachment])
        XCTAssertTrue(viaDescriptor.result?.text.contains(" T _main") == true, "\(String(describing: viaDescriptor.failure))")

        // The whole listing as a file: an attachment the other way.
        let listed = await client.call(tool: "symbols", arguments: ["binary": .string(binary), "output": "file"])
        guard let result = listed.result else { return XCTFail("\(String(describing: listed.failure))") }
        guard case let .file(file)? = result.content.last else { return XCTFail("no file in \(result.text)") }
        XCTAssertEqual(file.mimeType, "text/plain")
        XCTAssertEqual(file.name, "apelin-disassembler.symbols.txt")
        let attached = try String(decoding: file.readAll(limit: 32 << 20), as: UTF8.self)
        XCTAssertTrue(attached.contains(" T _main"))
        XCTAssertGreaterThan(attached.split(separator: "\n").count, 200, "unpaged: more than one page of symbols")
        XCTAssertTrue(result.text.hasPrefix("\(attached.split(separator: "\n").count - 2) matching symbols"), result.text)
        await client.terminate()
    }

    func testAssembleThenDisassemble() async throws {
        let assembler = try await client("apelin-assembler", manifest: manifest("assembler"))
        let assembled = await assembler.call(tool: "assemble", arguments: ["arch": "arm64", "source": "mov x0, #0x2a; ret"])
        guard let text = assembled.result?.text else { return XCTFail("\(String(describing: assembled.failure))") }
        XCTAssertTrue(text.contains("bytes: 40 05 80 d2 c0 03 5f d6"), text)
        XCTAssertTrue(text.contains("0xd2800540 0xd65f03c0"), text)

        let x86 = await assembler.call(tool: "assemble", arguments: ["arch": "x86_64", "source": "nop; ret"])
        XCTAssertTrue(x86.result?.text.contains("bytes: 90 c3") == true)
        let broken = await assembler.call(tool: "assemble", arguments: ["arch": "arm64", "source": "not an instruction"])
        XCTAssertEqual(broken.failure?.code, .toolFailed, "\(String(describing: broken.result?.text))")
        let pac = await assembler.call(tool: "assemble", arguments: ["arch": "arm64", "source": "pacibsp"])
        XCTAssertEqual(pac.failure?.code, .toolFailed, "\(String(describing: pac.result?.text))")
        await assembler.terminate()
    }
}
