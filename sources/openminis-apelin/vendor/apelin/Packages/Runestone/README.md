# Runestone

The editor's text view, vendored from source so the app carries the grammars
Apelin highlights instead of every grammar Tree-sitter has.
`Lakr233/Runestone.xcframework` links 38 languages into one static archive;
this package keeps the ones iOS development and its usual scripts use, and
adds the three it lacked (Objective-C, XML, Make). It starts from Irisin's
vendored copy (`Lakr233/Irisin` `Packages/Runestone` at `a0bd81d5`), which
carries the fixes below.

| Directory | What it is | Origin | License |
| --- | --- | --- | --- |
| `Sources/Runestone` | The text view | [simonbs/Runestone](https://github.com/simonbs/Runestone) 0.5.2 (`592434a1`), without its DocC catalog, by way of Irisin | MIT (`LICENSE`) |
| `Sources/TreeSitter` | Tree-sitter runtime (ABI 13–14) | [tree-sitter/tree-sitter](https://github.com/tree-sitter/tree-sitter), as `Lakr233/Runestone.xcframework` `2688e46` vendors it (`Vendor/RunestoneEditor/TreeSitter`) | MIT (`Sources/TreeSitter/LICENSE`) |
| `Sources/TreeSitterC`, `TreeSitterCPP`, `TreeSitterSwift`, `TreeSitterBash`, `TreeSitterPython`, `TreeSitterRuby`, `TreeSitterJSON`, `TreeSitterYAML`, `TreeSitterMarkdown`, `TreeSitterMarkdownInline` | Grammars | [simonbs/TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages), as the same xcframework commit vendors them (`Vendor/RunestoneEditor/RunestoneLanguageSupport/Sources/TreeSitter<Name>`); each upstream is named in `Licenses/tree-sitter-<name>/notice.json` | MIT (their `LICENSE`, the upstream grammar's) |
| `Sources/TreeSitterObjC` | Objective-C grammar (ABI 14) | [tree-sitter-grammars/tree-sitter-objc](https://github.com/tree-sitter-grammars/tree-sitter-objc) 3.0.2 (`181a81b8`), `src/` as released | MIT (`LICENSE`) |
| `Sources/TreeSitterXML` | XML grammar (ABI 14) | [tree-sitter-grammars/tree-sitter-xml](https://github.com/tree-sitter-grammars/tree-sitter-xml) 0.7.0 (`5000ae8f`), `xml/src/` and `common/scanner.h` | MIT (`LICENSE`) |
| `Sources/TreeSitterMake` | Makefile grammar (ABI 14) | [tree-sitter-grammars/tree-sitter-make](https://github.com/tree-sitter-grammars/tree-sitter-make) 1.1.1 (`70613f3d`), parser regenerated (below) | MIT (`LICENSE`) |
| `Sources/RunestoneLanguageSupport` | `RunestoneLanguage` (the file → language lookup), `RunestoneLanguageProvider` (injections) and every query, as string literals under `Queries/` | the queries and indentation rules of TreeSitterLanguages and of the three upstreams above | MIT (`LICENSE`, TreeSitterLanguages') |
| `Sources/RunestoneThemeSupport` | Tomorrow and One Dark | Runestone's example themes, colours written in code, by way of Irisin | MIT |

## Languages

| Language | Files (`RunestoneLanguage(fileName:)`) |
| --- | --- |
| C | `.c` |
| Objective-C | `.h`, `.m`, `.mm`; Logos `.x`, `.xm`, `.xi`, `.xmi` |
| C++ | `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hh`, `.hxx` |
| Swift | `.swift` |
| Bash | `.sh`, `.bash`, `.zsh`; `preinst`, `postinst`, `prerm`, `postrm`, `extrainst_` |
| Python | `.py` |
| Ruby | `.rb`, `.podspec`, `.gemspec`, `.rake`; `Podfile`, `Gemfile`, `Fastfile`, `Appfile`, `Matchfile`, `Pluginfile`, `Rakefile` |
| JSON | `.json`, `.xcstrings`; `Package.resolved` |
| YAML | `.yml`, `.yaml`; a package's `control` |
| Markdown (and Markdown inline, injected) | `.md`, `.markdown` |
| XML | `.xml`, `.plist`, `.entitlements`, `.xcprivacy`, `.xib`, `.storyboard`, `.xcscheme` |
| Make | `Makefile`, `makefile`, `GNUmakefile`, `.mk`, `.mak` |

Whole names are matched first, then the extension without case; anything
else is plain text.

- **Headers** (`.h`) read as Objective-C, which is C and more: a tweak's
  headers declare classes as often as functions.
- **Logos** has no grammar here. `.x` and `.xm` read as Objective-C: the
  `%hook`/`%orig` lines are parse errors drawn plain, and the Objective-C
  between them is coloured. `.mm` and `.xm` are Objective-C++; the
  Objective-C grammar reads them too, and C++-only syntax is drawn plain.
  An Objective-C++ grammar is not cheap: there is no maintained one.
- **`control`** reads as YAML, whose mappings colour a control file's
  fields; nothing in it is YAML beyond that.
- **Injections**: Markdown injects its fences (by info string, e.g.
  ```` ```swift ````, `objc`, `sh`, `make`) and its inline text, and a
  Makefile's recipes are Bash. Nothing kept injects tree-sitter-comment or
  tree-sitter-regex (only languages this package dropped did), so neither
  is here. HTML and LaTeX inside Markdown stay plain.

## What changed from upstream

- `TreeSitter/include/TreeSitter.h` completes each tree-sitter handle struct
  before `api.h`, since Xcode 27's importer skips an incomplete C struct, and
  `TreeSitterParser`, `TreeSitterQuery`, `TreeSitterQueryCursor` and
  `TreeSitterTree` hold typed pointers instead of `OpaquePointer` to match.
  The xcframework's `Script/assemble.py` makes the same change. Each
  grammar's `include/public.h` includes it rather than redeclaring
  `TSLanguage`.
- `TextView` dismisses the edit menu through `EditMenuController`, which
  keeps upstream's two paths: `UIEditMenuInteraction` on iOS 16 and later,
  `UIMenuController` below it.
- The themes read their colours from code instead of asset catalogs, and
  `HighlightName` no longer prints the names it does not know.
- The queries are string literals (`Queries/<Name>Queries.swift`), so the
  package ships no resource bundle for them; Runestone's own bundle
  (`Runestone_Runestone.bundle`: theme colours, strings, privacy manifest)
  is the only one. C++ is C's highlights followed by C++'s, as
  TreeSitterLanguages combines them.
- **Objective-C**: C's highlights followed by tree-sitter-objc's, which
  inherit C's (`; inherits: c` removed). Runestone evaluates only `eq?`,
  `not-eq?`, `match?`, `not-match?` and `set!`, and drops a capture with any
  other predicate, so the two `any-of?` lists are anchored `match?`
  alternations and the `has-ancestor?` pattern (struct fields, which C's
  `field_identifier` already colours) is gone. Capture names the themes do
  not know take one they do: `@include`, `@storageclass`, `@exception` and
  `@type.qualifier` become `@keyword.*`, `@method` becomes
  `@function.method`, `@parameter` becomes `@variable.parameter`, and
  `@text.uri` is dropped from `version_number`.
- **XML**: the `any-of?` of predefined entities is a `match?`, and tag
  names are `@keyword.tag` (the themes have no tag colour).
- **Make**: its two `any-of?` lists are `match?` alternations.
- **XML's scanner** includes its shared header as `common/scanner.h`
  (`src/common/`), not `../../common/scanner.h`, which would leave the
  target.
- **YAML**: `src/schema.generated.cc` is excluded from the target;
  `scanner.cc` includes it.

## Grammar ABI

The runtime reads grammars of ABI 13 and 14. tree-sitter-objc and
tree-sitter-xml ship ABI 14 parsers and are vendored as released.
tree-sitter-make 1.1.1 ships an ABI 15 parser, which this runtime refuses,
so `Sources/TreeSitterMake/src` (`parser.c` and `tree_sitter/`) is
regenerated from the upstream commit's own `src/grammar.json` with the
tree-sitter CLI 0.24.7, the last whose own ABI is 14:

```sh
cd tree-sitter-make            # a clone at 70613f3d
npx --yes tree-sitter-cli@0.24.7 generate --abi 14 src/grammar.json
cp src/parser.c <Apelin>/Packages/Runestone/Sources/TreeSitterMake/src/
cp -R src/tree_sitter <Apelin>/Packages/Runestone/Sources/TreeSitterMake/src/
```

A grammar outside 13–14 does not load, and its files show as plain text.

## Adding a language

Copy the grammar's `src/` into `Sources/TreeSitter<Name>/` with its
upstream `LICENSE` beside it and an `include/public.h` like the others; add
it to `grammars` in `Package.swift`, its queries as
`Queries/<Name>Queries.swift`, a case to `RunestoneLanguage` with its file
names and injection names, and a
`Licenses/tree-sitter-<name>/` folder with the same `LICENSE` (`make
check` fails without it). Rewrite any predicate Runestone does not
evaluate (it evaluates `eq?`, `not-eq?`, `match?`, `not-match?` and
`set!`; any other drops its capture without a word). Then install the
app on a vphone (`make vphone-app`) and open a file of that language,
and a file that injects it, to see them coloured: a bad query fails
silently there. Each grammar is paid for in the app's binary.
