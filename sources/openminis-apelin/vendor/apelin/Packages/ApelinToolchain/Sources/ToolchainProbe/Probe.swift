import ApelinToolchain
import Darwin
import Foundation

@main
struct Probe {
    static func main() async {
        let started = Date()
        var exitCode: Int32 = 0
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else { throw Usage() }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            func printJSON(_ value: some Encodable) throws {
                try print(String(decoding: encoder.encode(value), as: UTF8.self))
            }
            switch command {
            case "compatibility":
                struct Release: Encodable {
                    let version: String
                    let compatibility: ReleaseCompatibility
                    let swift: SwiftToolchainSupport?
                    let clangModuleCPUFeatures: [String]
                }
                struct Catalog: Encodable {
                    let cpuProfiles: [ToolchainCPUProfile]
                    let releases: [Release]
                }
                try printJSON(Catalog(
                    cpuProfiles: CommandLineToolsSupport.cpuProfiles,
                    releases: CommandLineToolsSupport.releases.map {
                        Release(
                            version: $0.version,
                            compatibility: $0.compatibility,
                            swift: $0.swiftSupport,
                            clangModuleCPUFeatures: $0.clangModuleCPUFeatures,
                        )
                    },
                ))
            case "catalog":
                try await printJSON(ToolchainCatalog().list())
            case "setup":
                guard args.count == 4 || (args.count == 5 && args[4] == "swift") else { throw Usage() }
                guard geteuid() == 501 else {
                    throw NSError(
                        domain: "probe",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Run setup as the mobile user (uid 501)."],
                    )
                }
                let sources = try await ToolchainCatalog().list()
                guard let source = sources.first(where: { $0.productID == args[1] }) else { throw Usage() }
                let start = Date()
                let components: Set<ToolchainComponent> = args.count == 5 ? [.base, .swift] : [.base]
                let manifest = try await ToolchainSetup().run(source: source, components: components, staging: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) { event in
                    let line = "\(Date().timeIntervalSince(start)) \(event.stage.rawValue) \(event.completedBytes) \(event.detail)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                FileHandle.standardError.write(Data("PIPELINE seconds=\(Date().timeIntervalSince(start))\n".utf8))
                try printJSON([
                    "id": manifest.id,
                    "fileCount": String(manifest.files.count),
                    "installRelativePath": manifest.installRelativePath,
                    "sourceSHA256": manifest.sourceSHA256,
                ])
            case "test":
                guard args.count == 4 else { throw Usage() }
                let results = try await ToolchainSelfTest().run(
                    toolchain: URL(fileURLWithPath: args[1]),
                    sdk: URL(fileURLWithPath: args[2]),
                    scratch: URL(fileURLWithPath: args[3]),
                )
                try printJSON(results)
                if results.contains(where: { !$0.passed }) {
                    exitCode = 1
                }
            default: throw Usage()
            }
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exitCode = 1 }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var children = rusage(); getrusage(RUSAGE_CHILDREN, &children)
        FileHandle.standardError.write(Data("METRICS seconds=\(Date().timeIntervalSince(started)) peakRSSBytes=\(usage.ru_maxrss) childMaxRSSBytes=\(children.ru_maxrss)\n".utf8))
        exit(exitCode)
    }

    struct Usage: Error, CustomStringConvertible {
        var description: String {
            "usage: apelin-toolchain-probe compatibility | catalog | setup PRODUCT_ID STAGING OUTPUT [swift] | test TOOLCHAIN PHYSICAL_SDK SCRATCH"
        }
    }
}
