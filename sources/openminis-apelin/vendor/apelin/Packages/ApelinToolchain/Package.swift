// swift-tools-version: 6.0
import Foundation
import PackageDescription

let settingsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Configuration/Platforms.xcconfig")
let settings = try String(contentsOf: settingsURL, encoding: .utf8)
func deploymentTarget(_ key: String) -> String {
    for line in settings.split(separator: "\n") {
        let fields = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if fields.count == 2, fields[0] == key {
            return fields[1]
        }
    }
    fatalError("Missing \(key) in Configuration/Platforms.xcconfig")
}

let package = Package(
    name: "ApelinToolchain",
    platforms: [
        .iOS(deploymentTarget("IPHONEOS_DEPLOYMENT_TARGET")),
        .macOS(deploymentTarget("MACOSX_DEPLOYMENT_TARGET")),
    ],
    products: [
        .library(name: "ApelinToolchain", targets: ["ApelinToolchain"]),
        .executable(name: "apelin-toolchain-probe", targets: ["ToolchainProbe"]),
    ],
    // The one signer, apelin-build's too (Irisin's, MIT). Only the
    // CryptoKit-only ApelinCodeSign links; ApelinFormats' libarchive pin
    // resolves but is not linked into anything here.
    dependencies: [.package(path: "../ApelinFormats")],
    targets: [
        .target(name: "CToolchainSystem", linkerSettings: [.linkedLibrary("z")]),
        .target(
            name: "ApelinToolchain",
            dependencies: ["CToolchainSystem", .product(name: "ApelinCodeSign", package: "ApelinFormats")],
        ),
        .executableTarget(name: "ToolchainProbe", dependencies: ["ApelinToolchain"]),
        .testTarget(
            name: "ApelinToolchainTests",
            dependencies: ["ApelinToolchain", .product(name: "ApelinCodeSign", package: "ApelinFormats")],
            resources: [.copy("Fixtures")],
        ),
    ],
    swiftLanguageModes: [.v5],
)
