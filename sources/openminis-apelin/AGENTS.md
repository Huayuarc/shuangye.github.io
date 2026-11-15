# OpenMinis-Apelin workspace

## Scope and provenance

Keep the OpenMinis host and its features. This workspace imports Apelin v0.4.7
at commit `05d899306d010dd739a4c03fcbf26825813d28c3` into `vendor/apelin`.
Do not modify installed Apelin, Irisin or their services, reuse their daemon
identity, or connect this integration to those services. A minimal independent
transport/service package exists in `src/native-development`; its iOS launcher
is explicitly unsupported. See `docs/apelin-integration.md` for verified
boundaries and the module map.

The host LICENSE is GPLv3. Preserve Apelin's MIT notice in
`vendor/apelin/LICENSE`, generated-file attribution, and dependency licenses.
The imported archive SHA256 is
`e78d26d99ae18081b4fe86929de71f6c23804cee67095d6f91b6f82fc159ceae`;
`docs/apelin-skill-sources.json` records the skill generator input digests.

## Checks that run now

Run from the project root:

```sh
python3 scripts/generate_apelin_skills.py --check
python3 scripts/check_apelin_build_environment.py
```

The first verifies generated skill source and its source manifest. The second is
a read-only prerequisite audit: exit 2 means prerequisites are missing, not that
the audit crashed. Neither command compiles or runs Swift. Do not describe source
inspection, generator checks or a zero exit from this device's unsupported
`plutil -lint` invocation as an application build.

On authorized macOS CI, `scripts/ci_build_openminis.sh` first runs the extracted
policy check and `sh src/native-development/Scripts/test-macos.sh`, then prepares
dependencies and compiles the full unsigned Minis scheme. The native test script
builds its independent service and requires real child-process tests; missing
Swift or a failed test is not a pass. iOS launch and service run remain unsupported.

## Build baseline and remaining blockers

The unsigned Minis Release baseline compiled in authorized macOS CI at source
commit `bf24258847ed6406d78107049dd882a9d1a151c6`, Actions run `43696702961`,
job `132758742001`. Subsequent native-service changes still need their own CI
run. Signing, install, app launch and dual-bootstrap packages remain unverified.
`apelin-project.json` currently has no external build script. Do not run
upstream Makefiles blindly or fabricate a package entry point that only copies
an upstream binary. Packages must be produced through `apelin_project_build`
after a real external build script is declared and reviewed; do not build a DEB
manually through shell commands.

A working C/Objective-C CLT 15.3 toolchain and SDK 17.4 exist on this iOS 16.1.2
device. The available toolchain catalog does not provide a compatible Swift 6.1
route for this host. Do not repeatedly query or force-install incompatible Swift
releases. Missing dependencies include the iSH submodule/libraries/headers,
Rclone framework, Alpine rootfs resource and LAME library. Inspect
`BUILDING.md` and dependency scripts before preparing them on a Mac.

BUILDING.md and project-level configurations specify iOS 26.2/Swift 6.0; the
main app target overrides deployment to 16.0 and language mode to Swift 5. The
widget targets 16.2. These existing settings do not establish iOS 16.1.2
compatibility: source references iOS 26 APIs. A suitable Swift compiler/SDK build
route and an explicit iOS 16 compatibility review are needed before any claim that
this device can run the full integration. Mac/Xcode or an authorized CI is one
possible route, not evidence that this phone cannot support development tools.
Do not remove features or substitute
a different host without the user's decision.

## Next build and runtime validation

First establish a usable compiler/SDK route. The phone supports the installed
C/Objective-C toolchain; absence of a suitable Swift component in the current
catalog is a separate limitation. If choosing a Mac or CI, obtain authorization
for that environment and source transfer, then prepare Xcode/SDK, recursive
dependencies and Swift package resolution. The CI authorization below supersedes
the earlier lack of a named build environment.
Review all unavailable APIs, app extensions and entitlements for iOS 16.1.2,
preserving the requested host features. The user has now authorized the existing
public CI repository `https://github.com/Huayuarc/shuangye.github.io.git`, branch
`main`, for complete source transfer and an independent OpenMinis workflow.
Use `sources/openminis-apelin`, preserve existing Theos workflows, and never force
push. `scripts/ci_build_openminis.sh` performs dependency preparation and unsigned
host compilation on Xcode/SDK 26.2+; `scripts/export_openminis_ci_source.py` audits
and exports source with file digests and fixed submodule commits. Neither script
creates a release package. Local syntax/generator/export checks are not Swift
compilation. Release publication and first installation remain separate steps. Compile the app and independent backend,
then wire a real external packaging entry point with logical bootstrap paths.
Settle permanent bundle/package IDs with the user before first installation.
Build rootless and roothide release packages separately and validate both.

On a compiled app, exercise `apelin_skill_list`, skill and companion reads,
legacy aliases, missing/unknown arguments, and `apelin_integration_status`.
Verify that status does not advertise backend capabilities until they actually
exist. Then test each backend operation and dispatch-site authorization with
its independent service before enabling it. No runtime checks have yet run.

The original goal remains full Apelin v0.4.7 development integration while
preserving the OpenMinis host: skills, Strict/Relaxed/Full approval, toolchains
and self-tests, SDKs, templates, native commands and jailbreak files, build/sign/
install, diagnostics, load confirmation and device tests, followed by verified
rootless and roothide release packages. This first-stage source handoff does not
complete that goal. Keep the pending module map in
`docs/apelin-integration.md` current. The authorized macOS/Swift/SDK build route
has a successful unsigned baseline. Validate each subsequent integration snapshot
there; independent iOS service launch and runtime/package review remain open.
No decision to discard host features has been made.

## Paths and collaboration

Never persist a resolved roothide root in code, scripts or documentation. Use
project-relative paths or runtime variables such as `${APELIN_PROJECT_ROOT:?}`
and `${SDKROOT:?}`. Future package layouts use logical paths and supported
prefix substitutions. Do not touch unrelated apps or installed services.

Coordinate file ownership between conversations. Do not commit unbuilt code as
a successful milestone. Do not push, publish, install or change repository
history without the relevant user authorization.
