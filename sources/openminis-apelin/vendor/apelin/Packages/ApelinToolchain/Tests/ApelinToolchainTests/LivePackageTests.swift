@testable import ApelinToolchain
import Foundation
import Testing

/// Opt-in local smoke test. Apple payloads are never committed as test fixtures.
struct LivePackageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APELIN_TEST_PACKAGE"] != nil))
    func `extracts real apple package`() throws {
        let input = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["APELIN_TEST_PACKAGE"]))
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try PackageArchive(limits: .init()).extract(input, to: root)
        let clt = try canonical(root.appendingPathComponent("Library/Developer/CommandLineTools"))
        var closure = DependencyClosure(root: clt, components: [.base])
        let selected = try closure.select()
        #expect(selected["usr/bin/llvm-otool"] != nil)
        for (relative, source) in selected where !relative.hasPrefix("usr/lib/clang/") {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            if data.count >= 4, try data.number(0, as: UInt32.self) == 0xFEED_FACF {
                print("Retargeting \(relative)")
                var image = try MachOImage(data)
                try image.retarget(minimumOS: 0x100000) { name, _ in MachOImage.flattened(name) }
                _ = try image.signed(identifier: source.lastPathComponent)
            }
        }
    }
}
