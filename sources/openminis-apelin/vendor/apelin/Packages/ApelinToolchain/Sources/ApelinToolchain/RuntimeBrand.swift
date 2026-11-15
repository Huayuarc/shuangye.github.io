import CryptoKit
import Foundation

/// RootHide brands a tool on first execution: a jbrand in the unused half
/// of __text's segment name, CS_ADHOC, and the resulting first-page hash.
/// Compare that file with its original manifest without changing it. The
/// reconstructed *whole file* must still have the expected SHA-256; code,
/// dependencies, entitlements and every other byte remain covered.
func matchesToolchainDigest(_ file: URL, expected: String) throws -> Bool {
    if try digestFile(file) == expected {
        return true
    }
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    guard let original = try? removingRuntimeBrand(from: data) else { return false }
    try Task.checkCancellation()
    return sha256(original) == expected
}

/// Only the thin arm64, SHA-256/4 KB signature our retargeter writes is
/// accepted. A malformed mark or signature is a mismatch, not a reason to
/// relax the comparison. This restores bytes in memory only.
func removingRuntimeBrand(from data: Data) throws -> Data {
    let image = try MachOImage(data)
    guard image.bytes.count == data.count else { throw ToolchainFailure("Runtime brand needs a thin image") }
    var marks: [Int] = []
    var offset = 32
    for command in image.commands {
        defer { offset += command.bytes.count }
        guard command.kind == 0x19,
              try command.bytes.fixedString(8 ..< 24) == "__TEXT"
        else { continue }
        let count = try Int(command.bytes.number(64, as: UInt32.self))
        for index in 0 ..< count {
            let section = 72 + index * 80
            guard try command.bytes.fixedString(section ..< section + 16) == "__text",
                  command.bytes.subdata(in: section + 16 ..< section + 24) == Data("__TEXT\0\0".utf8)
            else { continue }
            let mark = command.bytes.subdata(in: section + 24 ..< section + 32)
            guard mark.contains(where: { $0 != 0 }), mark.reduce(UInt8(0), ^) == 0 else { continue }
            marks.append(offset + section + 24)
        }
    }
    guard marks.count == 1, let mark = marks.first, mark + 8 <= 4096 else {
        throw ToolchainFailure("No valid runtime brand")
    }
    let signatures = image.commands.filter { $0.kind == 0x1D }
    guard signatures.count == 1, let command = signatures.first else {
        throw ToolchainFailure("Runtime brand needs one signature")
    }
    let signature = try Int(command.bytes.number(8, as: UInt32.self))
    let size = try Int(command.bytes.number(12, as: UInt32.self))
    guard signature >= 4096, size == data.count - signature,
          try data.number(signature, as: UInt32.self, big: true) == 0xFADE_0CC0
    else { throw ToolchainFailure("Invalid runtime signature") }
    let length = try Int(data.number(signature + 4, as: UInt32.self, big: true))
    let count = try Int(data.number(signature + 8, as: UInt32.self, big: true))
    guard length >= 12, length <= size, count <= (length - 12) / 8 else {
        throw ToolchainFailure("Invalid runtime signature index")
    }
    var directories: [Int] = []
    for index in 0 ..< count {
        let entry = signature + 12 + index * 8
        guard try data.number(entry, as: UInt32.self, big: true) == 0 else { continue }
        let relative = try Int(data.number(entry + 4, as: UInt32.self, big: true))
        guard relative >= 12 + count * 8, relative <= length - 44 else {
            throw ToolchainFailure("Invalid runtime code directory")
        }
        directories.append(signature + relative)
    }
    guard directories.count == 1, let directory = directories.first,
          try data.number(directory, as: UInt32.self, big: true) == 0xFADE_0C02,
          try data.number(directory + 12, as: UInt32.self, big: true) == 2,
          data.subdata(in: directory + 36 ..< directory + 40) == Data([32, 2, 0, 12]),
          try data.number(directory + 32, as: UInt32.self, big: true) == UInt32(signature)
    else { throw ToolchainFailure("Unsupported runtime code directory") }
    let directoryLength = try Int(data.number(directory + 4, as: UInt32.self, big: true))
    let hashes = try Int(data.number(directory + 16, as: UInt32.self, big: true))
    let slots = try Int(data.number(directory + 28, as: UInt32.self, big: true))
    guard directoryLength >= 44, directoryLength <= signature + length - directory,
          hashes >= 44, hashes <= directoryLength - 32,
          slots == (signature + 4095) / 4096, slots <= (directoryLength - hashes) / 32
    else { throw ToolchainFailure("Invalid runtime page hashes") }
    let firstHash = directory + hashes
    guard data.subdata(in: firstHash ..< firstHash + 32) == Data(SHA256.hash(data: data.prefix(4096))) else {
        throw ToolchainFailure("Runtime brand has an invalid page signature")
    }
    var original = data
    original.replaceSubrange(mark ..< mark + 8, with: Data(count: 8))
    original.put(UInt32(0), at: directory + 12)
    original.replaceSubrange(firstHash ..< firstHash + 32, with: Data(SHA256.hash(data: original.prefix(4096))))
    return original
}
