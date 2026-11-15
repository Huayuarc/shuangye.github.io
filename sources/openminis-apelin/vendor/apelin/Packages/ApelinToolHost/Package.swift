// swift-tools-version:5.9
//
// The agent-tool-extension protocol: both ends of it, and nothing else.
//
// - ApelinToolCore: the frames, the manifest and its validation, the
//   attachment channel. Imported by both sides.
// - ApelinToolHost: `ToolHostClient`, which spawns one extension process and
//   talks to it. The session host links this.
// - ApelinToolExtension: `ToolExtensionServer`, which an extension executable
//   links to implement its tools.
//
// System libraries only: the session host links this, and nothing
// third-party links into the host side.

import PackageDescription

let package = Package(
    name: "ApelinToolHost",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ApelinToolCore", targets: ["ApelinToolCore"]),
        .library(name: "ApelinToolHost", targets: ["ApelinToolHost"]),
        .library(name: "ApelinToolExtension", targets: ["ApelinToolExtension"]),
    ],
    targets: [
        .target(name: "ApelinToolCore"),
        .target(name: "ApelinToolHost", dependencies: ["ApelinToolCore"]),
        .target(name: "ApelinToolExtension", dependencies: ["ApelinToolCore"]),
        // A test double: an extension that misbehaves on request. Built for
        // the tests only; no product names it.
        .executableTarget(name: "FakeToolExtension", dependencies: ["ApelinToolExtension"]),
        .testTarget(
            name: "ApelinToolHostTests",
            dependencies: ["ApelinToolHost", "ApelinToolExtension", "FakeToolExtension"],
        ),
    ],
)
