# Repository Guidelines

## Project Structure & Module Organization

This repository is a Theos jailbreak tweak for SpringBoard. Core tweak code lives at the repository root: `Tweak.x` contains Logos hooks, and `DIContentView.*`, `DIDisplayManager.*`, `DIWindow.*`, and `DILocalization.*` implement UI, presentation, windowing, and localization helpers. Injection scope is defined in `DynamicIslandTweak.plist` and should remain limited to intended bundles such as `com.apple.springboard`.

The preference bundle lives in `dynamicislandprefs/`, with controller code in `DIRootListController.*`, metadata in `entry.plist`, and resources under `dynamicislandprefs/Resources/`. PreferenceLoader install-time assets are under `layout/Library/PreferenceLoader/Preferences/`. Private runtime headers are stored in `私有头文件/`. Generated build output belongs in `.theos/` and `packages/`; do not edit generated artifacts directly.

## Build, Test, and Development Commands

- `make clean`: removes Theos build artifacts before rebuilding or switching package schemes.
- `make package`: builds the tweak and preference bundle into a `.deb` package.
- `THEOS_PACKAGE_SCHEME=rootless make clean package`: performs a clean rootless build.
- `THEOS_PACKAGE_SCHEME=roothide make clean package`: performs a clean roothide compatibility build.

Run commands from the repository root. Use the `THEOS` path from `Makefile`; do not hardcode preboot paths in source or scripts.

## Coding Style & Naming Conventions

Use Objective-C and Logos with ARC enabled through `-fobjc-arc`. Keep project classes prefixed with `DI`, use descriptive method names, and follow the existing four-space indentation style. Keep hook logic lightweight: validate private classes and selectors at runtime, avoid heavy I/O in hooks, and dispatch UI work to the main thread. User-facing strings must use `NSLocalizedString` with matching `en.lproj` and `zh-Hans.lproj` resources.

## Testing Guidelines

There is no automated test suite in this checkout. Validate changes with a clean package build, then test on the intended jailbreak scheme and iOS version. Confirm SpringBoard behavior, preference loading, localization, and crash-free operation. For crashes, inspect `/var/mobile/Library/Logs/CrashReporter/` and verify selector signatures, object types, paths, signing, and entitlements.

## Commit & Pull Request Guidelines

No readable Git history is available in this checkout, so use concise imperative commit messages such as `Fix notification layout sizing` or `Add preference localization`. Pull requests should describe the target package scheme, tested iOS version, build command used, visible UI changes, and any relevant crash logs or screenshots.

## Security & Configuration Tips

Keep the filter plist narrowly scoped. Avoid collecting private user data or logging sensitive content. Prefer rootless and roothide-compatible paths, keep Mach-O files out of jbroot `/var` and `/tmp`, and declare only required dependencies in `control`.
