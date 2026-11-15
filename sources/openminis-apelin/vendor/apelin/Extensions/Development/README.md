# Development extensions

The four packages that teach Apelin to make something. Each folder here is
exactly what its package installs at
`<install-root>/usr/share/apelin/development/<id>/` — `manifest.json`,
`templates/`, `support/`, `LICENSE` — and nothing in it is executed: the app
reads the manifest and copies template files, the build reads headers and
link stubs. The formats are specified in
[`Documents/Schemas/README.md`](../../Documents/Schemas/README.md).

| Package | Templates | Support | Depends (beyond `wiki.qaq.apelin (>= 0.1.0)`) |
|---|---|---|---|
| `wiki.qaq.apelin.dev.app` | `uikit-objc`, `uikit-swift` (Swift component required) | — | `uikittools` |
| `wiki.qaq.apelin.dev.tweak` | `objc-hook` | `substrate`: `substrate.h`, `libsubstrate.tbd` per bootstrap | `mobilesubstrate` |
| `wiki.qaq.apelin.dev.cli` | `c`, `objc` | — | — |
| `wiki.qaq.apelin.dev.preferences` | `objc-bundle` | `preferences`: `Preferences/PSListController.h`, `Preferences.framework/Preferences.tbd` | `preferenceloader` |

An extension depends on what the packages built from its templates need at
run time (`requirements.runtimeDependencies` and its support components'),
so a template that builds also runs. The packager derives `Depends` from the
manifest; nothing is retyped in the control files.

Every template's `package.icon` is its extension's own icon on Apelin's
Pages, `https://owngoal-dev.github.io/Apelin/icons/<id>.png` (from app and
tweak 0.1.1, cli and preferences 0.1.2), so a package built from it shows
that icon in a package manager until the user names their own;
`check-templates.py` fails a template whose icon is another or not a file
in `Documents/Site`. That icon is the package manager's, not the Settings
row's: from preferences 0.1.3 the `objc-bundle` bundle carries the row's own,
`Resources/icon.png` with its @2x and @3x (29 points), the extension's plate
as the app's `ProjectIconPreferences` image set draws it, which the entry's
`icon` names and the developer replaces.

## What each template proves

- **objc-hook** — a dylib filtered to `com.apple.springboard` that calls
  `MSHookMessageEx` on `-[SpringBoard applicationDidFinishLaunching:]` (the
  method `Documents/Research/ApelinHello` hooked on the iOS 27 vphone) and
  logs, under the package id's os_log subsystem, `ApelinLoaded <build id> in
  <process>` from its constructor and `ApelinHooked <build id> …` from the
  hook. `apelin_package_confirm_loaded` matches the first; the second shows the hook API was
  really called.
- **uikit-objc / uikit-swift** — a scene-based app whose `main` deletes this
  bundle's saved scene state before `UIApplicationMain`, one screen with its
  version and build id, and the entitlements an app outside a container
  needs (with the GPU user-client list and why).
- **c / objc** — a tool with `--version`, `--help`, a greeting and sysexits
  exit codes, so acceptance checks output and status, and from 0.1.1 the
  app templates' GPU user-client list in its entitlements, so a tool that
  calls VideoToolbox, Core Video or Metal gets its IOSurfaces.
- **objc-bundle** — a `PSListController` subclass loading `Root.plist` with a
  switch and a text field stored in the package's own domain, posting
  `<package id>/changed`, and the PreferenceLoader entry with its row's icon.

## The hook API

`wiki.qaq.apelin.dev.tweak` ships its own header and stubs; it does not
assume the SDK has substrate interfaces.

- `support/include/substrate.h` — MIT, written for Apelin from the published
  signatures. The declared compatible set is `MSHookMessageEx`,
  `MSHookFunction`, `MSGetImageByName`, `MSFindSymbol`.
- `support/lib/rootless/libsubstrate.tbd` — install name
  `@rpath/CydiaSubstrate.framework/CydiaSubstrate`; the build adds LC_RPATH
  `/var/jb/Library/Frameworks` and `/var/jb/usr/lib` (manifest `rpaths`,
  spelled `@PREFIX@/…`).
- `support/lib/roothide/libsubstrate.tbd` — install name
  `@loader_path/.jbroot/usr/lib/libsubstrate.dylib`, roothide's own
  convention for an image inside the jbroot.
- Runtime: the virtual package `mobilesubstrate`, which the bootstraps'
  ElleKit provides on both layouts; no implementation is named. The
  libhooker API (`LHHookFunctions`, …) is not in the compatible set: only
  some providers carry it, and `mobilesubstrate` does not promise it.

The install names are the layout ElleKit installs and that Theos's own
rootless and roothide stubs link against (read from
`owngoal-dev/theos-lib` at `514d1395`, for the install names only; nothing
was copied). They are checked on the Mac by linking; on a device only
by the D-stage acceptance run.

`wiki.qaq.apelin.dev.preferences` does the same for the private Preferences
framework: its own declarations and a stub with the install name
`/System/Library/PrivateFrameworks/Preferences.framework/Preferences`
exporting `PSListController` (and its `_specifiers` ivar), `PSSpecifier` and
`PSViewController`, so a pane links against any registered SDK, with or
without PrivateFrameworks.

## Where the templates come from

Recorded per scope in each manifest's `provenance`, with the adaptations.

| Template | Source | Commit |
|---|---|---|
| `objc-hook`, `objc-bundle` | `platformize-tweak-ios` (local; not yet published under `owngoal-dev`) | `26910cd8c524165a085232d72559b66ae0cc298c` |
| `uikit-objc`, `uikit-swift` | `github.com/owngoal-dev/platformize-app-ios` | `0aac1f88779f86e4288cd99fd6e330ce4df56d3f` |
| `c`, `objc` | `github.com/owngoal-dev/platformize-bin-ios` | `ffb7085a6cfb53eb89512da15a9cb3ba209ecbc9` |

All three are OwnGoal Studio's, MIT. Searched on 2026-10-17: none of the
`owngoal-dev` repositories or the 221 under `Lakr233` is otherwise a
template, skeleton or starter by name or description; the published tweaks
there are finished Theos projects, not templates. Every template
source file carries an SPDX MIT header, so a generated project keeps the
notice.

## Checking and packaging

```sh
Extensions/Development/check-templates.py [--write-digests] [--no-build]
Extensions/Development/package-extensions.sh <output-directory> [roothide|rootless ...]
```

`check-templates.py` validates every manifest and template the way the
scanner does, instantiates each template with its defaults, validates the
generated project and prints its build and packaging digests, then builds it
on the Mac with Xcode's iPhoneOS SDK by its own typed steps for every
bootstrap it names — a stand-in for `apelin-build`, to prove the sources,
headers and stubs compile and link. `--write-digests` refreshes each
template's digest after a template edit.

`package-extensions.sh` runs the check (set `APELIN_EXTENSIONS_NO_BUILD=1` to
skip the build half), then for each extension and flavor stages the folder
at `@PREFIX@/usr/share/apelin/development/<id>/` (`@PREFIX@` empty for
roothide, `/var/jb` for rootless), fills `Packaging/<id>/control`, builds
with `dpkg-deb --root-owner-group -Zzstd`, and verifies Package, Version,
Architecture and Depends, that every entry is root-owned 0755/0644, nothing
is executable, nothing lies outside the data folder, and that the extracted
copy passes the manifest, template and digest checks. Output is
`<id>_<version>_<arch>.deb` and a SHA-256 list.

## Proposed changes outside this folder (not made here)

**`Packaging/DEBIAN/control`** — add, after `Depends:`:

```
Recommends: wiki.qaq.apelin.dev.app, wiki.qaq.apelin.dev.tweak, wiki.qaq.apelin.dev.cli, wiki.qaq.apelin.dev.preferences
```

The IDE stays free of any injection framework: only the tweak extension
depends on one, and a package manager that skips recommendations installs
the IDE alone. Removing an extension is never an error.

**`Makefile`** — a `deb-extensions` target running
`Extensions/Development/package-extensions.sh $(ROOT_DIR)/build/Packages`,
added to `deb-all`, and `Documents/Schemas/Tools/check-fixtures.py` plus
`Extensions/Development/check-templates.py --no-build` in `check`.

**`ci.yml` / `manifest.json`** — the extension debs land in `build/Packages/`
beside the IDE's, so the existing artifact and release carry them; the
owngoal-packages entry lists the four package ids with their own versions.

## Published templates

Templates are a read-only catalog shipped with Apelin. New templates and changes to existing templates are contributed through pull requests to this repository; the app does not maintain a separate user template library.

`make template-archive` validates the manifests and template digests, then writes `build/Packages/Apelin_<version>_Templates.tar.zst`. It contains every development extension's template sources, support files and licenses, plus `catalog.json` with the app version and the built-in empty workspace. File ordering, ownership metadata and timestamps are fixed for reproducible output. The packager decompresses and compares every byte before accepting the archive. CI builds this archive, includes it in `SHA256SUMS`, and Release publishes those verified bytes alongside the packages.
