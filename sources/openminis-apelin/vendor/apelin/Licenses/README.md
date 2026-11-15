# Bundled notices

Settings → About → Licenses lists every notice the app ships under, with the
full text a push away. Apelin's own code is MIT; third-party code keeps its
own license.

`Scripts/collect-licenses.py` runs offline as the app target's last build
phase, Collect Licenses, and writes `Apelin.app/Licenses.json` from:

1. the repository `LICENSE`;
2. the folders here, one per component that ships inside a prebuilt binary
   with no license file of its own — each holds the full notice as `LICENSE`
   and a `notice.json` (name, source URL, content hash, and the version or
   the checkout file it is read from);
3. every pin in `Package.resolved`, its checkout walked for nested notices.

`review.json` records the reviewed text hash and display label of every
notice, and the reviewed revision of every package that ships a prebuilt
binary. A changed or missing notice, a new component, or a binary upgrade
fails the build until a person re-reads it and updates this file. The labels
are reviewed descriptions, not a keyword verdict. `Licenses.json` goes into
the app bundle only, never into apelind.

The workers' dependencies: icli (with libarchive.xcframework, a prebuilt
binary whose `LICENSE` carries libarchive, xz, zstd and lz4 in full; its
revision is in `binaryRevisions`) in apelin-diagnostics; kwwk with its whole
tree (swift-nio, swift-nio-ssl and the BoringSSL it compiles,
swift-nio-http2, swift-crypto, swift-asn1, swift-atomics, swift-collections,
swift-system, swift-argument-parser as a pin, libwebp, libpng, zlib, Cstb) in
apelin-agent; libgit2 in apelin-environment. Folders here: `BoringSSL`
(compiled from swift-nio-ssl's checkout, which has no license file for it),
`ios-mcp` (icli keeps that notice as `Resources/Licenses/ios-mcp.txt`, a name
the collector does not walk) and `libgit2`. `review.json`'s `excludedPaths`
lists folders a pin's own manifest never compiles — libpng's `ci` and
`contrib`, zlib's `contrib` — which hold notices, one of them GPL text, for
code that does not ship.

The app's dependencies (owner, 2026-10-17): DisplayLink, ListViewKit,
Litext, MarkdownView (with SwiftMath, swift-cmark, LRUCache and
swift-collections), libghostty-spm, and Runestone, vendored from source in
`Packages/Runestone` with only the grammars Apelin highlights. Runestone's
notices have folders here, each the same text as the `LICENSE` beside the
vendored source (`make check` compares them): `Runestone`, `tree-sitter`
(the runtime), `TreeSitterLanguages` (the queries) and one
`tree-sitter-<language>` per grammar. libghostty ships a prebuilt static
binary whose wrapper's LICENSE covers only the packaging, so what it holds
has folders here too: libghostty holds `ghostty` and one `ghostty-<component>` per library
compiled into libghostty.a (FreeType under the FTL, Oniguruma, libpng,
zlib, wuffs, simdutf, Highway, stb, libxev, z2d, zig-objc, uucode, the two
embedded fonts, the Zig runtime and libc++'s headers), plus one
`ghostty-nerd-fonts-<set>` per glyph set in the embedded Symbols Nerd Font
(Nerd Fonts 3.4.0's `license-audit.md`). SwiftMath's math
fonts (`font-<name>`) are here because their licence files are `OFL.txt`
and `GUST-FONT-LICENSE.txt`, names the collector does not walk.

The wheels the sibling apps share (owner, 2026-10-17), app only: SPIndicator,
AlertController, Then, SnapKit, SwifterSwift and Dog, each pin's own `LICENSE` walked as usual.

The editor's webpage import uses FlowDown's ScrubberKit 0.2.0, pinned to
its revision, with SwiftSoup and Turndown. All are MIT. Turndown's upstream
notice has the nonstandard filename `turndown-license`, so its full text is
also kept in `Licenses/turndown/` for the generated list.

GPL-family text fails the build unless `review.json` ▸ `gplExceptions`
names that exact notice, its text hash and (for a package) the pinned
revision, with the owner's acceptance; `Compatibility.md` says why for each.
libgit2 and z2d (MPL-2.0, whose definition of "Secondary License" names the GNU licences) are the two today.

A new dependency's notices are added here in the same commit, one folder
per component, and `Compatibility.md` gets a row for it.
