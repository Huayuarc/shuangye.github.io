import ApelinCodeSign
@testable import ApelinToolchain
import Foundation
import Testing

struct ToolchainTests {
    func fixture(_ path: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + path)
    }

    @Test func `catalog retains upstream identity`() throws {
        let plist: [String: Any] = ["Products": ["one": ["Packages": [["URL": "http://swcdn.apple.com/test/CLTools_Executables.pkg", "Size": 42, "Digest": "abcd"]]]]]
        let sources = try ToolchainCatalog.parse(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)).sources
        #expect(sources.count == 1)
        #expect(sources.first?.url.scheme == "https")
        #expect(sources.first?.upstreamDigest == "abcd")
        #expect(sources.first?.productID == "one")
    }

    @Test(arguments: ["Fixture.dylib", "FixtureBundle", "FixtureUnsigned.dylib", "fixture-tool", "FixtureApp", "FixtureCodesigned", "FixtureUnsignedTool"])
    func `preserved irisin signature fixtures`(name: String) throws {
        // Rebuild the signature over the original signed bytes, not through our retargeter.
        // This compares the port with independently generated device ldid fixtures.
        let image = try MachOImage(Data(contentsOf: fixture("expected/" + name)))
        let command = try #require(image.commands.first { $0.kind == 0x1D })
        let offset = try Int(command.bytes.number(8, as: UInt32.self)), length = try Int(command.bytes.number(12, as: UInt32.self))
        let blob = image.bytes.subdata(in: offset ..< offset + length)
        let count = try Int(blob.number(8, as: UInt32.self, big: true))
        var slots: [UInt32: Data] = [:]
        for i in 0 ..< count {
            let slot = try blob.number(12 + i * 8, as: UInt32.self, big: true), at = try Int(blob.number(16 + i * 8, as: UInt32.self, big: true))
            let size = try Int(blob.number(at + 4, as: UInt32.self, big: true))
            slots[slot] = blob.subdata(in: at ..< at + size)
        }
        let directory = try #require(slots[0])
        var signature = LdidStyleSignature(identifier: name)
        if let xml = slots[5], let der = slots[7] {
            let entitlements = try LdidEntitlements(xml: Data(xml.dropFirst(8)))
            #expect(try entitlements.xml() == Data(xml.dropFirst(8)))
            #expect(entitlements.der == Data(der.dropFirst(8)))
            signature.entitlements = try (entitlements.xml(), entitlements.der)
        }
        signature.executableSegmentFlags = try directory.number(80, as: UInt64.self, big: true)
        for command in image.commands where command.kind == 0x19 {
            let n = try Int(command.bytes.number(64, as: UInt32.self))
            for i in 0 ..< n {
                let p = 72 + i * 80
                if try command.bytes.cString(p ..< p + 16) == "__info_plist" {
                    let start = try Int(command.bytes.number(p + 48, as: UInt32.self)), length = try Int(command.bytes.number(p + 40, as: UInt64.self))
                    signature.infoPlist = image.bytes.subdata(in: start ..< start + length)
                }
            }
        }
        let base = try directory.number(64, as: UInt64.self, big: true), limit = try directory.number(72, as: UInt64.self, big: true)
        let rebuilt = signature.blob(code: Data(image.bytes.prefix(offset)), executable: (base, limit))
        #expect(rebuilt + Data(count: (16 - rebuilt.count % 16) % 16) == blob)
    }

    @Test func `retarget and sign`() throws {
        var image = try MachOImage(Data(contentsOf: fixture("input/FixtureBundle")))
        try image.retarget(minimumOS: 0x100000) { name, _ in name }
        let signed = try image.signed(identifier: "FixtureBundle")
        let reread = try MachOImage(signed)
        let platform = try #require(reread.commands.first { $0.kind == 0x32 })
        #expect(try platform.bytes.number(8, as: UInt32.self) == 2)
        #expect(try platform.bytes.number(12, as: UInt32.self) == 0x100000)
        #expect(reread.uuid == image.uuid)
    }

    @Test(arguments: ["fixture-tool", "Fixture.dylib"])
    func `only self test executables are debuggable`(name: String) throws {
        for selfTest in [false, true] {
            var image = try MachOImage(Data(contentsOf: fixture("input/" + name)))
            let data = try image.signed(identifier: name, forSelfTest: selfTest)
            // The entitlement is in the XML signature slot, so its spelling
            // also verifies that compiler and library signatures do not gain it.
            let xml = String(decoding: data, as: UTF8.self)
            #expect(xml.contains("get-task-allow") == (selfTest && image.fileType == 2))
        }
    }

    @Test func `dsym virtual sections have no file bytes`() throws {
        var data = Data(count: 32 + 152)
        data.put(UInt32(0xFEED_FACF), at: 0)
        data.put(UInt32(0x100000C), at: 4)
        data.put(UInt32(10), at: 12)
        data.put(UInt32(1), at: 16)
        data.put(UInt32(152), at: 20)
        data.put(UInt32(0x19), at: 32)
        data.put(UInt32(152), at: 36)
        data.put(UInt32(1), at: 32 + 64)
        data.put(UInt64(4096), at: 32 + 72 + 40)
        _ = try MachOImage(data, allowDSYM: true)
        data.put(UInt32(2), at: 12)
        #expect(throws: (any Error).self) { try MachOImage(data) }
    }

    @Test func `insufficient command space is explicit`() throws {
        var image = try MachOImage(Data(contentsOf: fixture("input/FixtureBundle")))
        try image.retarget(minimumOS: 0x100000) { _, _ in String(repeating: "x", count: 200_000) }
        #expect(throws: (any Error).self) { try image.signed(identifier: "x") }
    }

    @Test func `truncations do not trap`() throws {
        let original = try Data(contentsOf: fixture("input/FixtureBundle"))
        for end in stride(from: 0, through: 2048, by: 7) {
            #expect(throws: (any Error).self) { try MachOImage(Data(original.prefix(end))) }
        }
        var corrupt = original; corrupt.put(UInt32.max, at: 20)
        #expect(throws: (any Error).self) { try MachOImage(corrupt) }
    }

    @Test func `framework flattening`() {
        #expect(MachOImage.flattened("/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation") == "/System/Library/Frameworks/Foundation.framework/Foundation")
        #expect(MachOImage.flattened("usr/lib/Versions/A/foo") == "usr/lib/Versions/A/foo")
    }

    @Test(arguments: ["../escape", "/absolute", "a/../../escape", "bad\0path"])
    func `rejects archive escape`(path: String) throws {
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-test-" + UUID().uuidString)
        try directory(root); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try PackageArchive(limits: .init()).extractCPIO(MemoryReader(cpio(path, mode: 0o100644, body: Data("x".utf8))), root: root) }
    }

    @Test func `rejects symlink chain and devices`() throws {
        for archive in [cpio("link", mode: 0o120777, body: Data("../escape".utf8)), cpio("device", mode: 0o020666, body: Data())] {
            let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-test-" + UUID().uuidString)
            try directory(root); defer { try? FileManager.default.removeItem(at: root) }
            #expect(throws: (any Error).self) { try PackageArchive(limits: .init()).extractCPIO(MemoryReader(archive), root: root) }
        }
    }

    @Test func `extracts odc and enforces budget`() throws {
        let archive = cpio("./file", mode: 0o100644, body: Data("hello".utf8)) + cpio("TRAILER!!!", mode: 0, body: Data())
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-test-" + UUID().uuidString)
        try directory(root); defer { try? FileManager.default.removeItem(at: root) }
        try PackageArchive(limits: .init()).extractCPIO(MemoryReader(archive), root: root)
        #expect(try Data(contentsOf: root.appendingPathComponent("file")) == Data("hello".utf8))
        var limits = ToolchainArchiveLimits(); limits.expandedBytes = 4
        #expect(throws: (any Error).self) { try PackageArchive(limits: limits).extractCPIO(MemoryReader(archive), root: root) }
    }
}

private final class MemoryReader: ByteReader {
    let data: Data; var offset = 0
    init(_ data: Data) {
        self.data = data
    }

    func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw ToolchainFailure("Truncated fixture") }
        defer { offset += count }; return data.subdata(in: offset ..< offset + count)
    }
}

private func cpio(_ name: String, mode: Int, body: Data) -> Data {
    let fields = [0, 1, mode, 501, 501, 1, 0].map { String(format: "%06o", $0) }.joined()
    let header = "070707" + fields + String(format: "%011o%06o%011o", 0, name.utf8.count + 1, body.count)
    return Data(header.utf8) + Data(name.utf8) + Data([0]) + body
}
