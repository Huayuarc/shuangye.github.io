@testable import ApelinToolchain
import Foundation
import Testing

/// Opt-in, offline inventory of exactly the host images the retarget selects.
/// It thins Apple's package to arm64 but never executes, signs or installs it.
/// Feed the resulting manifest to Scripts/inspect-toolchain-imports.py.
struct StaticInventoryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APELIN_STATIC_PACKAGE"] != nil))
    func `prepare host images`() throws {
        let environment = ProcessInfo.processInfo.environment
        let package = try URL(fileURLWithPath: #require(environment["APELIN_STATIC_PACKAGE"]))
        let output = try URL(fileURLWithPath: #require(environment["APELIN_STATIC_WORKSPACE"]))
        let version = try #require(environment["APELIN_STATIC_VERSION"])
        try #require(!FileManager.default.fileExists(atPath: output.path))
        try directory(output)
        let extracted = output.appendingPathComponent("extracted")
        defer { try? FileManager.default.removeItem(at: extracted) }
        try PackageArchive(limits: .init()).extract(package, to: extracted)
        let root = try canonical(extracted.appendingPathComponent("Library/Developer/CommandLineTools"))
        let tree = output.appendingPathComponent("host-images")
        try directory(tree)
        var closure = DependencyClosure(root: root, components: [.base, .swift])
        let selected = try closure.select()
        var files: [String: String] = [:]
        for (relative, file) in selected.sorted(by: { $0.key < $1.key }) {
            if relative.hasPrefix("usr/lib/clang/") {
                continue
            } // target inputs, never host code
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.count >= 4,
                  try [0xFEED_FACF, 0xBEBA_FECA].contains(data.number(0, as: UInt32.self)) else { continue }
            let arm = try MachOImage.armSlice(data)
            let path = tree.appendingPathComponent(relative)
            try directory(path.deletingLastPathComponent())
            try arm.write(to: path)
            files[relative] = sha256(arm)
        }
        struct Inventory: Encodable {
            struct Source: Encodable { let version: String }
            let inventoryOnly = true
            let source: Source
            let sourceSHA256: String
            let files: [String: String]
        }
        try writeJSON(Inventory(source: .init(version: version), sourceSHA256: digestFile(package), files: files),
                      to: tree.appendingPathComponent("manifest.json"))
        print("STATIC_INVENTORY_READY \(version) \(files.count) host images")
    }
}
