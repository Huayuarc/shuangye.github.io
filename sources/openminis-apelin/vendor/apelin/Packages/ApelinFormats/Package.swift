// swift-tools-version: 6.0
import PackageDescription

/// The file formats Apelin reads and writes on the device: Mach-O images, and
/// Debian packages in both directions. Nothing here imports UIKit, spawns a
/// process or knows the install prefix; every target builds and tests on a Mac
/// with plain `swift test`.
///
/// - `ApelinMachO` reads Mach-O through a descriptor or a buffer, bounds-checked.
///   No dependencies, so a privileged process may link it.
/// - `ApelinDebian` is the text side of a package: control paragraphs, version
///   ordering, the control file generator and the bootstrap layouts. No
///   dependencies.
/// - `ApelinDebArchive` reads and writes `.deb` files. The one target with a
///   third-party dependency, and never linked into apelind.
/// - `ApelinCodeSign` signs a Mach-O the way `ldid -Hsha256 -S` does
///   (Irisin's signer). CryptoKit only. The one signer: ApelinToolchain's
///   retarget uses its signature and entitlements blobs too.
let package = Package(
    name: "ApelinFormats",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ApelinMachO", targets: ["ApelinMachO"]),
        .library(name: "ApelinDebian", targets: ["ApelinDebian"]),
        .library(name: "ApelinDebArchive", targets: ["ApelinDebArchive"]),
        .library(name: "ApelinCodeSign", targets: ["ApelinCodeSign"]),
    ],
    dependencies: [
        // The same package and version Irisin's reader and Fila's archive jobs
        // use: every compression filter a .deb can carry (gzip, xz, zstd, ...)
        // for reading and writing, plus the ar and tar readers, in one static
        // binary. Through the package rather than a binary target of our own,
        // because icli brings the same package into the app's graph and two
        // targets named `libarchive` do not resolve.
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "ApelinMachO"),
        .target(name: "ApelinDebian"),
        .target(name: "ApelinCodeSign", exclude: ["LICENSE"]),
        .target(
            name: "ApelinDebArchive",
            dependencies: [
                "ApelinDebian",
                .product(name: "ArchiveKit", package: "libarchive.xcframework"),
            ],
        ),
        .testTarget(
            name: "ApelinMachOTests",
            dependencies: ["ApelinMachO"],
            exclude: ["Fixtures/build.sh", "Fixtures/fixture.c", "Fixtures/pointer-auth.c"],
            resources: [.copy("Fixtures/binaries")],
        ),
        .testTarget(
            name: "ApelinDebianTests",
            dependencies: ["ApelinDebian"],
            resources: [.copy("Fixtures")],
        ),
        .testTarget(
            name: "ApelinCodeSignTests",
            dependencies: ["ApelinCodeSign", "ApelinMachO"],
            exclude: ["Fixtures/build.sh", "Fixtures/fixture.c"],
            resources: [.copy("Fixtures/input"), .copy("Fixtures/expected"), .copy("Fixtures/entitlements.plist")],
        ),
        .testTarget(
            name: "ApelinDebArchiveTests",
            dependencies: ["ApelinDebArchive", "ApelinDebian"],
        ),
    ],
    swiftLanguageModes: [.v6],
)
