@testable import ApelinToolchain
import CryptoKit
import Foundation
import Testing

struct RuntimeBrandTests {
    private func sample() throws -> (data: Data, mark: Int, directory: Int, hashes: Int, code: Int) {
        let resources = try #require(Bundle.module.resourceURL)
        let url = resources.appendingPathComponent("Fixtures/input/FixtureCodesigned")
        var image = try MachOImage(Data(contentsOf: url))
        let text = try #require(image.commands.firstIndex {
            $0.kind == 0x19 && (try? $0.bytes.fixedString(8 ..< 24)) == "__TEXT"
        })
        try #require(image.commands[text].bytes.number(64, as: UInt32.self) >= 2)
        // C++ tools have full-width names without a terminating NUL.
        image.commands[text].bytes.replaceSubrange(152 ..< 168, with: Data("__gcc_except_tab".utf8))
        let data = try image.signed(identifier: "runtime-brand-fixture")
        let signed = try MachOImage(data)
        var offset = 32
        var mark: Int?
        for command in signed.commands {
            defer { offset += command.bytes.count }
            guard command.kind == 0x19 else { continue }
            let count = try Int(command.bytes.number(64, as: UInt32.self))
            for index in 0 ..< count {
                let section = 72 + index * 80
                if try command.bytes.fixedString(section ..< section + 16) == "__text" {
                    mark = offset + section + 24
                }
            }
        }
        let signature = try #require(signed.commands.first { $0.kind == 0x1D })
        let start = try Int(signature.bytes.number(8, as: UInt32.self))
        let count = try Int(data.number(start + 8, as: UInt32.self, big: true))
        var directory: Int?
        for index in 0 ..< count where try data.number(start + 12 + index * 8, as: UInt32.self, big: true) == 0 {
            directory = try start + Int(data.number(start + 16 + index * 8, as: UInt32.self, big: true))
        }
        let cd = try #require(directory)
        return try (data, #require(mark), cd, cd + Int(data.number(cd + 16, as: UInt32.self, big: true)), signed.firstContent)
    }

    private func brand(_ data: Data, mark: Int, directory: Int, hashes: Int) -> Data {
        var result = data
        // A synthetic jbrand with the required XOR checksum; no device ID.
        result.put(UInt64(0x0102_0304_0506_0700), at: mark)
        result.put(UInt32(2).bigEndian, at: directory + 12)
        result.replaceSubrange(hashes ..< hashes + 32, with: Data(SHA256.hash(data: result.prefix(4096))))
        return result
    }

    @Test func `restores only the runtime metadata`() throws {
        let fixture = try sample()
        let branded = brand(fixture.data, mark: fixture.mark, directory: fixture.directory, hashes: fixture.hashes)
        #expect(try removingRuntimeBrand(from: branded) == fixture.data)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try branded.write(to: file)
        #expect(try matchesToolchainDigest(file, expected: sha256(fixture.data)))
        #expect(try Data(contentsOf: file) == branded, "verification does not write the installed tool")
    }

    @Test(arguments: ["code", "signature", "mark", "dependency", "entitlements", "signature index"])
    func `rejects changes outside the runtime metadata`(change: String) throws {
        let fixture = try sample()
        var changed = brand(fixture.data, mark: fixture.mark, directory: fixture.directory, hashes: fixture.hashes)
        switch change {
        case "code":
            changed[fixture.code] ^= 1
            let page = fixture.code / 4096
            let range = try page * 4096 ..< min((page + 1) * 4096, Int(changed.number(fixture.directory + 32, as: UInt32.self, big: true)))
            changed.replaceSubrange(fixture.hashes + page * 32 ..< fixture.hashes + (page + 1) * 32, with: Data(SHA256.hash(data: changed.subdata(in: range))))
        case "signature": changed[fixture.hashes] ^= 1
        case "mark":
            changed[fixture.mark] ^= 1
            changed.replaceSubrange(fixture.hashes ..< fixture.hashes + 32, with: Data(SHA256.hash(data: changed.prefix(4096))))
        case "entitlements":
            let key = try #require(changed.range(of: Data("platform-application".utf8)))
            changed[key.lowerBound] ^= 1
        case "signature index":
            let image = try MachOImage(changed)
            let command = try #require(image.commands.first { $0.kind == 0x1D })
            let signature = try Int(command.bytes.number(8, as: UInt32.self))
            changed.put(UInt32.max.bigEndian, at: signature + 8)
        default:
            let name = Data("/usr/lib/".utf8)
            let range = try #require(changed.range(of: name))
            changed[range.lowerBound + 1] ^= 1
            changed.replaceSubrange(fixture.hashes ..< fixture.hashes + 32, with: Data(SHA256.hash(data: changed.prefix(4096))))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try changed.write(to: file)
        #expect(try !matchesToolchainDigest(file, expected: sha256(fixture.data)))
    }

    @Test func `malformed data stays A mismatch`() throws {
        let fixture = try sample()
        for data in [Data(), Data(fixture.data.prefix(32)), Data(fixture.data.dropLast(1))] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            try data.write(to: file)
            #expect(try !matchesToolchainDigest(file, expected: sha256(fixture.data)))
        }
    }
}
