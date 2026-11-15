# Apelin — Checklist

One time, before any code is written. `make check` runs
`Scripts/check-checklist.sh` first, and every build target depends on it, so
nothing builds until every box below is ticked.

Tick a box only after doing or deciding the thing, never to get past the gate.
An item that does not apply here is ticked with the reason written after it.
A decision is recorded where the item says (usually `AGENTS.md`), so the next
reader finds the answer and not only the tick. "SKILL.md" is
platformize-app-ios's; the quoted name is its section.

## Identity and rename

- [x] The daemon shape is chosen (on-demand, session host or helper-per-job) and is the one-sentence idea at the top of `AGENTS.md`.
      SKILL.md "Pick the daemon shape".
      **Done:** Session host (iGhostVT shape), at the top of `AGENTS.md`; the launchd job is on demand and idle-exits only when it has no work (owner, 2026-10-16).
- [x] `Scripts/`, `Makefile`, `.gitignore` and the release workflow are copied from the sibling of that shape, and `.gitignore` ignores `.build/` and `.swiftpm/`.
      SKILL.md "Template".
      **Done:** From iGhostVT 860cbc4 (Scripts, Makefile, .gitignore) and Irisin a0bd81d5 (workflows), then rewritten for Apelin; `.gitignore` has both.
- [x] `grep -rn '@[A-Z_]*@' --exclude-dir=.git .` shows only the packager's tokens (`@PREFIX@`, `@VERSION@`, `@ARCHITECTURE@`, `@FLAVOR@`, `@INSTALLED_SIZE@`).
      SKILL.md "Template", Placeholders.
      **Done:** Only the packager's tokens remain (`@PREFIX@`, `@VERSION@`, `@ARCHITECTURE@`, `@FLAVOR@`, `@INSTALLED_SIZE@`).
- [x] The sibling-name sweep prints nothing, `DERIVED_DATA`, `mktemp` prefixes and the workflow's `concurrency.group` included.
      SKILL.md "Template": the rename is finished when the sweep is empty.
      **Done:** Empty outside `AGENTS.md`'s credits once the untracked `IrisinIDE/` leftover is deleted.
- [x] The bundle id, daemon id, Mach service and client entitlement are all named after this app and shared with no other.
      SKILL.md "The contract", peer authentication.
      **Done:** `wiki.qaq.apelin`, `wiki.qaq.apelind`, `wiki.qaq.apelin.service`, `wiki.qaq.apelin.client`.
- [x] The hooks survived the rename: `grep -nE '[A-Za-z0-9_@]2>' Packaging/DEBIAN/*` prints nothing and the daemon id appears once in each hook.
      SKILL.md "Template": replace the token and nothing around it.
      **Done:** Both greps clean; `make check` now enforces the once-per-hook count.
- [x] `AGENTS.md` has no placeholder left and no section that is untrue here; there is no `CLAUDE.md`, and no file names a package manager.
      `AGENTS.md`; SKILL.md "The contract".
      **Done:** Placeholders filled, a Decisions section added, no `CLAUDE.md`, no package manager named.

## Daemon and trust boundary

- [x] The wire is a closed list of operations written down in `AGENTS.md`; none of them is `exec(path, argv)`.
      SKILL.md "The contract": nothing generic executes.
      **Done:** `AGENTS.md` ▸ Decisions ▸ The wire: every milestone 1 operation in `AppOperation`, all data, with the four places an operation is added.
- [x] The authenticator's checks and their order are written down, and `platform-application` is required of the peer only if `Packaging/<App>.entitlements` carries it.
      SKILL.md "The contract": peer authentication.
      **Done:** `AGENTS.md` ▸ Decisions; the app carries `platform-application`, so the authenticator requires it.
- [x] The backend is resolved at runtime: `hello` answers an enum carrying the install root, and no build flag or compilation condition tells the wrappers apart.
      SKILL.md "The contract", first bullet.
      **Done:** `hello` answers the install root; no build flag or condition anywhere.
- [x] A missing daemon is *Connecting…*; the fallback grace period is a duration, and the hello timeout is a chosen number of seconds guarded by connection generation.
      SKILL.md "The contract": a hello has a bound.
      **Done:** 5 s hello bound per attempt guarded by generation, 1 s retry, 10 s grace from the first miss (`AGENTS.md` ▸ Decisions).
- [x] Every optional key in the launchd plist (`KeepAlive`, `RunAtLoad`, `AbandonProcessGroup`, `ProcessType`) is enabled or deleted to match the shape.
      `Packaging/<daemon id>.plist`; SKILL.md "Template".
      **Done:** On demand (owner, 2026-10-16): no `RunAtLoad`, no `KeepAlive`; launchd starts apelind through `MachServices`, and apelind's `WorkLedger` exits 30 s after its last connection, request and session-host work, past launchd's respawn throttle. `Interactive` + 10240 files. No `AbandonProcessGroup`: the session host and workers are apelind's children and go with it. `make check` asserts all of it.
- [x] `Scripts/check-launchd-paths.py` is copied in and wired into `make check` against the launchd plist; any watched, logged or working path is spelled `@PREFIX@/…` or `@ROOTFS@/…`, and the packager fills `@ROOTFS@` if one is used.
      SKILL.md "Every path launchd itself opens names its root".
      **Done:** Wired; the plist has no launchd path beyond its program, so no `@ROOTFS@` (the packager fills it if one appears).
- [x] Nothing third-party links into the daemon, and whether a CLI (a second peer) exists is decided and written down.
      SKILL.md "The contract"; "Layout".
      **Done:** Nothing third-party in either binary; no CLI (`AGENTS.md` ▸ Decisions).

## Bootstrap detection

- [x] No install prefix is written in Swift: the daemon derives it from its own `proc_pidpath` and refuses to start from an unrecognised path.
      SKILL.md "The contract".
      **Done:** apelind derives the root from `proc_pidpath` and exits `EX_CONFIG` from any other path.
- [x] `Shared/RoothideRoot.swift` is in the project unchanged and is the only bootstrap check made before `hello`: no `dlopen` of libroothide through `.jbroot`, no "`/var/jb`, so rootless" fallback.
      `Shared/RoothideRoot.swift`; SKILL.md "The contract": roothide is recognised by the process's own path.
      **Done:** Identical to the template (diffed); nothing else checks the bootstrap before `hello`.
- [x] Every path is canonicalised (`realpath(3)`, NUL rejected) before a decision is made about it.
      SKILL.md "The contract".
      **Done:** `canonicalPath` rejects NUL, then `realpath(3)`; the authenticator compares canonical paths.

## Packaging and entitlements

- [x] The entitlement files and the launchd plist carry this app's names; `HELPER.entitlements` is renamed for a helper-per-job daemon and deleted otherwise.
      SKILL.md "Template".
      **Done:** `Apelin.entitlements`, `Apelind.entitlements`, `wiki.qaq.apelind.plist`; no helper, so no `HELPER.entitlements`.
- [x] The App Group key is kept only if an extension shares a container and the packager substitutes `$(APP_GROUP_IDENTIFIER)`.
      `Packaging/<App>.entitlements`.
      **Done:** No extension: the App Group key and `APP_GROUP_IDENTIFIER` are gone, and `make check` refuses them.
- [x] `storage.AppBundles` and `storage.AppDataContainers` are on the app and on the daemon if either reads another app's bundle or container, and on neither if not; every data-vault class is on the process that writes there.
      `Packaging/*.entitlements`; SKILL.md "The contract": `no-sandbox` does not open another app's bundle.
      **Done:** On both: a tweak targets another app, whose bundle the editor and agent read. Reason written in the entitlements file.
- [x] `com.apple.security.iokit-user-client-class` is present if the app draws with Metal itself, absent if not.
      `Packaging/<App>.entitlements`.
      **Done:** Present: every ad-hoc app needs it (IconServices, Bold Text), and the terminal will draw with Metal.
- [x] `control` depends on `firmware (>= <floor>)`, `uikittools` and `launchctl`; no hook calls `uicache`; `postinst` boots out system, user/501 and gui/501.
      **Done:** `firmware (>= 16.0), uikittools, launchctl`; no `uicache` in hooks; three bootouts. All enforced by `make check`.
- [x] `postinst` makes `/var/mobile/Documents/<bundle id>` level by level for mobile (no `mkdir -p` as root, no symlink followed), and the app keeps its files in that folder, never loose in `Documents`.
      `Packaging/DEBIAN/`; SKILL.md "The contract".
      **Done:** Template postinst unchanged; verified on the vphone (mobile owns `Documents` and `wiki.qaq.apelin`).
- [x] Versions and the deployment target live in `Configuration/*.xcconfig` only, `objectVersion` is pinned, `make check` rejects both, and one build-number style is chosen.
      SKILL.md "The contract".
      **Done:** Versions and floor in xcconfig only (`make check`); objectVersion 77; build number passed on the xcodebuild line (Irisin style).
- [x] The floor is chosen; `check-symbol-availability.py` is in `Scripts/` and wired in; XPC constants are read through `Shared/XPCShim` only.
      SKILL.md "The deployment floor is not what you set".
      **Done:** Floor 16.0 (MarkdownView); `check-symbol-availability.py` gates `check`; XPC through `AppXPC`. `audit-ios-floor.sh` gated `deb` until 2026-10-21, when the owner removed it: the floor is proven on a device (`Documents/Research/Device-Validation.md`).
- [x] The packager ad-hoc signs every embedded library, re-reads entitlements from the signed binaries, and greps every binary for the build path.
      SKILL.md "The contract".
      **Done:** `package-deb.sh` signs every Frameworks dylib/framework, re-reads app and daemon entitlements, greps every binary.

## App lifecycle

- [x] `main.swift` calls `UIApplicationMain` by hand after the saved-state reset and the app delegate is not `@main`, or the exception is written in `AGENTS.md`.
      `App/main.swift`, `App/SceneRestorationReset.swift`; SKILL.md "The contract".
      **Done:** `main.swift` resets saved state then calls `UIApplicationMain`; the delegate is not `@main`.
- [x] `ExecutableWatch.swift` is in the project unchanged, started once early in `didFinishLaunching`; omitted only for a self-updating installer.
      `App/ExecutableWatch.swift`.
      **Done:** Unchanged from the template (diffed), started first in `didFinishLaunching`; tested by `make harness`.
- [x] `QuietExit.swift` is in the project unchanged and is the only caller of `exit` in the app.
      `App/QuietExit.swift`; SKILL.md "The contract": Quit never calls `exit` from the foreground.
      **Done:** Unchanged (diffed); `make check` fails on any other `exit` in the app.
- [x] The root is a real tab bar for more than three top-level pages and a single navigation stack for three or fewer, never a `UITabBarController` with its bar hidden.
      SKILL.md "Gotchas observed across the apps".
      **Done:** A single navigation stack with a Settings button; the rule is in `AGENTS.md` ▸ Decisions.
- [x] Layout asks the window for its size class and the room it has, never the idiom or a device's size, and insets each edge by its own safe-area inset.
      iphone-duo-readiness, "Hunt the fixed assumptions": regular width is not always an iPad, and a vertical bar insets one side only.
      **Done:** The root tiles the sidebar only beside a page 402 pt wide and is a drawer otherwise; the conversation's list, composer and chevron keep to the safe area edge by edge (`AGENTS.md` ▸ Decisions ▸ The root, The SDK tier).

## Accessibility

- [x] `Scripts/check-accessibility.py` is copied in and wired into `make check`, so a label on a cell or view that UIKit will never read fails the build.
      SKILL.md "The contract": a label on a container that is not an accessibility element is never read.
      **Done:** Wired over `Apelin/`.
- [x] Every icon-only button and bar button item is labelled as it is written, the label is set beside the state it describes rather than once at construction, and no label repeats what VoiceOver already reads.
      SKILL.md "The contract": a control with no text has no name.
      **Done:** The one icon-only button, Settings, is labelled where it is made; nothing repeats a read label.
- [x] State that is only drawn — a checkmark, a selection, a progress fill — is an `accessibilityValue` or a trait, and nothing posts `.layoutChanged` on a routine view swap.
      SKILL.md "The contract": state that is only drawn is not spoken; accessibility is semantics, never behaviour.
      **Done:** No drawn-only state yet; no `.layoutChanged` anywhere.

## Assets and icons

- [x] The app icon is never looked up by name: every in-app use draws an ordinary image set, `AppIconMark`, and no source says `UIImage(named: "AppIcon")`.
      SKILL.md "The contract": the app icon is never looked up by name.
      **Done:** No `UIImage(named: "AppIcon")` (`make check` greps for it); no in-app icon use yet, so no `AppIconMark` set.
- [x] Another app's icon is asked of IconServices first; the fallback reads `CFBundleIconFiles` names as files with `UIImage(contentsOfFile:)`, never `UIImage(named:in:)`. Ticked as not applicable if the app shows none.
      SKILL.md "The contract", same bullet.
      **Done:** Not applicable: Apelin shows no other app's icon yet.
- [x] The app icon is `AppIcon.appiconset` with three JPEGs written by `scripts/render-app-icon.py`, no `.icon` is in any target (the source lives in `Documents/Icon/`), and `xcrun assetutil --info` on the built `Assets.car` shows every `AppIcon` rendition as JPEG. A changed icon was checked on a device after removing the package, not over it.
      SKILL.md "The contract": the app icon ships as three JPEGs in a plain icon set.
      **Done:** Three JPEGs; `assetutil` shows all six AppIcon renditions as JPEG; the `.icon` is in no target. Checked on the vphone after `dpkg -r`, then a fresh install: the leaf icon shows.
- [x] `Documents/Site/icon.png` exists and the depiction's banner is the largest image the README references.
      SKILL.md "Native Depiction".
      **Done:** `icon.png` exists; it is the only image the README references, so it is the banner until a wide one is made.

## Strings and licences

- [x] One catalogue discipline is chosen (compiler `.stringsdata` with no `extractionState`, or `manual` keys pruned by hand) and its gate is in `make check`.
      SKILL.md "Localization is verified against the compiler".
      **Done:** The manual discipline (`AGENTS.md` ▸ Decisions); `check-stale-strings.py` is the gate.
- [x] `Scripts/check-stale-strings.py` is copied in and wired into `make check`, so a key Xcode reaped during a build cannot ride into a commit unseen.
      SKILL.md "Localization is verified against the compiler": nothing else catches the marker.
      **Done:** Wired over `Apelin/`.
- [x] Every target's source root is written down for `prune-xcstrings.py` — app, extensions, macOS, visionOS, packages — and `--delete-orphans` is used only if this app has one target.
      SKILL.md: stale does not mean dead; a missing root deletes live strings and their translations.
      **Done:** `Apelin Apelind Shared` (`AGENTS.md` ▸ Decisions); one target, `--delete-orphans` still not used.
- [x] One licence discipline is chosen (scanned or reviewed), and the collector, the Collect Licenses build phase, the screen and both gates are in before the first dependency.
      SKILL.md "Licenses are collected by the build".
      **Done:** Reviewed (Fila's): collector, build phase, Settings ▸ About ▸ Licenses, and both gates, before any dependency.
- [x] `LICENSE` names the right holder and year, and every dependency's licence is read before its API: no GPL, no LGPL.
      `LICENSE`; SKILL.md "Licenses", vendored source.
      **Done:** MIT, OwnGoal Studio, 2026; no dependency yet.

## Release and debugging

- [x] `ci.yml` and `release.yml` are both in, copied as a pair: CI builds and keeps `<app>-<sha>` for thirty days, Release waits for that run, compiles nothing, and publishes the artifact CI verified.
      SKILL.md "Publishing": CI builds, Release publishes what CI built.
      **Done:** Both in, trimmed: CI runs the harness beside deb-all and keeps `apelin-<sha>` 30 days; Release compiles nothing.
- [x] The SDK the app is linked against is chosen, `make build` refuses an older one, the packager reads it back from the app it ships, and CI selects that Xcode by name.
      iphone-duo-readiness, "Establish the baseline": the SDK, not the floor, decides how an iPhone Duo lays the app out.
      **Done:** iOS 27.1 (`IOS_SDK_TIER`, `AGENTS.md` ▸ Decisions ▸ The SDK tier); CI on the `xcode-27` image with Xcode 27.1.
- [x] The release workflow is named `Release`, shaped test ‖ compile → release, and publishes one dSYM zip per build listed in `SHA256SUMS`.
      SKILL.md "Publishing"; "Native Depiction".
      **Done:** Named `Release`; CI's test ‖ build, then Release publishes; one dSYM zip in `SHA256SUMS`.
- [x] CI's concurrency keys a push on `github.sha` and a pull request on `github.ref`, so a push's run survives to be published by a tag on that commit.
      SKILL.md "Publishing": the concurrency keys are not decoration.
      **Done:** `github.sha` for a push, `github.ref` for a pull request.
- [x] `<docs>/Releases/` exists and the first release's note is written before its tag: a headline sentence, a bullet per user-visible change, a closing line naming the package and `SHA256SUMS`.
      SKILL.md "Publishing": the release notes are a file in the repo.
      **Done:** `Documents/Releases/` exists; the 0.1.0 note is written before its tag.
- [x] Pages is set to GitHub Actions and `manifest.json` points its icon at the Pages URL.
      SKILL.md "Publishing".
      **Not applicable yet:** the repository stays private, so Pages is not enabled. `manifest.json` already points at the Pages URL; set Pages to GitHub Actions when the repository goes public.
- [x] Release builds are `dwarf-with-dsym`, and the dSYM of every build installed on a device is kept until that build is gone from the device.
      SKILL.md "A crash is read before anything is changed".
      **Done:** Release is `dwarf-with-dsym`; the vphone build's dSYMs are kept in `build/dSYMs/0.1.0-2/` (UUIDs match the package).
- [x] The sensitive-information read-through is a step of every push, tag and release, and `AGENTS.md` says so.
      SKILL.md "The contract".
      **Done:** `AGENTS.md` ▸ Decisions says so.
