@testable import ApelinToolchain
import Foundation
import Testing

/// Opt-in preparation for reproducible probes, using ordinary reviewed setup.
/// The resulting tree is never installed or registered by this fixture.
struct LegacySwiftInvestigationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APELIN_LEGACY_SWIFT_VERSION"] != nil))
    func `prepare swift tree`() async throws {
        #if os(macOS)
            let environment = ProcessInfo.processInfo.environment
            let version = try #require(environment["APELIN_LEGACY_SWIFT_VERSION"])
            let workspacePath = try #require(environment["APELIN_LEGACY_SWIFT_WORKSPACE"])
            try #require(workspacePath.hasPrefix("/"))
            let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
            let output = workspace.appendingPathComponent("tree", isDirectory: true)
            try #require(!FileManager.default.fileExists(atPath: output.path), "never replace an existing research tree")
            let sources = try await ToolchainCatalog().list()
            let source = try #require(sources.first { $0.version == version })
            let manifest = try await ToolchainSetup().run(
                source: source, components: [.base, .swift],
                staging: workspace.appendingPathComponent("staging"), output: output,
            )
            try ToolchainSetup.verify(manifest, at: output)
            print("RESEARCH_TREE_READY \(source.version) \(manifest.files.count) files")
        #endif
    }
}
