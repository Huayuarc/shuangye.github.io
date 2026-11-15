// swift-tools-version: 6.0

import PackageDescription

/// Runestone, vendored: simonbs/Runestone's text view, the Tree-sitter runtime,
/// and only the grammars Apelin highlights. README.md says where each part
/// came from, what changed, and how a grammar is added.
let grammars: [(name: String, cxx: Bool, exclude: [String])] = [
    ("TreeSitterBash", true, []),
    ("TreeSitterC", false, []),
    ("TreeSitterCPP", true, []),
    ("TreeSitterJSON", false, []),
    ("TreeSitterMake", false, []),
    ("TreeSitterMarkdown", false, []),
    ("TreeSitterMarkdownInline", false, []),
    ("TreeSitterObjC", false, []),
    ("TreeSitterPython", true, []),
    ("TreeSitterRuby", true, []),
    ("TreeSitterSwift", false, []),
    ("TreeSitterXML", false, []),
    // scanner.cc includes the schema; compiled alone it is not a unit.
    ("TreeSitterYAML", true, ["src/schema.generated.cc"]),
]

let package = Package(
    name: "Runestone",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(name: "Runestone", targets: ["Runestone"]),
        .library(name: "RunestoneLanguageSupport", targets: ["RunestoneLanguageSupport"]),
        .library(name: "RunestoneThemeSupport", targets: ["RunestoneThemeSupport"]),
    ],
    targets: [
        // lib.c includes every other runtime source; compiling them again
        // would define each symbol twice.
        .target(
            name: "TreeSitter",
            exclude: ["LICENSE"],
            sources: ["src/lib.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        // Upstream's own sources, written before strict concurrency.
        .target(
            name: "Runestone",
            dependencies: ["TreeSitter"],
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
                .process("TextView/Appearance/Theme.xcassets"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("ConciseMagicFile"),
            ]
        ),
        .target(
            name: "RunestoneLanguageSupport",
            dependencies: ["Runestone", "TreeSitter"] + grammars.map { .target(name: $0.name) },
            exclude: ["LICENSE"]
        ),
        .target(
            name: "RunestoneThemeSupport",
            dependencies: ["Runestone"]
        ),
    ] + grammars.map { grammar in
        .target(
            name: grammar.name,
            dependencies: ["TreeSitter"],
            exclude: ["LICENSE"] + grammar.exclude,
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")],
            cxxSettings: grammar.cxx ? [.headerSearchPath("src")] : []
        )
    },
    cxxLanguageStandard: .cxx17
)
