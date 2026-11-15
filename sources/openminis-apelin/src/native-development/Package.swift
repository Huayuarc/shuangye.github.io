// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NativeDevelopment",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "MinisNativeDevelopment", targets: ["MinisNativeDevelopment"]),
        .executable(name: "native-development-service", targets: ["NativeDevelopmentService"])
    ],
    targets: [
        .target(name: "MinisNativeDevelopment", path: "Sources/NativeDevelopment"),
        .executableTarget(name: "NativeDevelopmentService", dependencies: ["MinisNativeDevelopment"]),
        .testTarget(name: "NativeDevelopmentTests", dependencies: ["MinisNativeDevelopment"])
    ]
)
