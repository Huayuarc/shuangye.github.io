# Apelin integration status

This workspace integrates source from Apelin v0.4.7, commit
`05d899306d010dd739a4c03fcbf26825813d28c3`, under `vendor/apelin`.
OpenMinis retains its existing app and agent architecture. Vendoring the source
does not connect OpenMinis to an installed Apelin, Irisin or daemon service.

## Host-first architecture (user-confirmed)

OpenMinis is the primary application and agent. Preserve its UI, conversations,
model providers, existing skills and memory, and iSH/Linux sandbox workflows.
Apelin v0.4.7 supplies development implementation and backend components; do not
replace the OpenMinis agent or combine two independent app bundles into one package.

Development skills, Strict/Relaxed/Full approval, toolchains, SDKs, templates,
native filesystem/commands, build/sign/install, load confirmation, logs/crashes
and device testing enter through OpenMinis's existing tool registration and
result-dispatch layers. Development approval is distinct from legacy offload
command/session permission. A separate native service must have independent
identity and validate each privileged operation, not reuse installed services.

Execution context must remain explicit: existing shell_execute and file tools
operate in iSH/Linux; native iOS operations require dedicated adapters. Never
silently redirect a sandbox command to the device or infer native capabilities
from Linux tool availability. Available tools advertise only connected features.

Compatibility targets iOS 16, preserving host features through reviewed API
availability handling. RootHide resolves its changing bootstrap path at runtime;
rootless uses its own logical prefix. Neither compatibility nor either package
has been verified. Full Swift compilation and dual-bootstrap release packaging
await actual macOS CI results. Source upload and normal push to the existing
public `Huayuarc/shuangye.github.io` repository on `main` are user-authorized;
no new remote is authorized. The independent workflow compiles unsigned for
diagnostics only; it does not publish an app, service or release package.

Current source review: definitions append to the host registry, the concurrent
host dispatcher handles the four read-only integration tools, and the existing
Linux shell branch remains separate. The embedded skills, partial policy and
approval queue follow this architecture. Native execution, complete approval
policy and independent service integration are still missing, so the architecture
is not evidence that those capabilities work.

## Native authorization protocol boundary (design, not a transport)

The local context store has no tool-facing configuration entry point. Its
snapshot starts absent; verified host project selection initializes Strict and
Ask Before Screen, and every local selection/settings change cancels pending
approvals and rotates the context revision. The current host has not yet wired
project selection or settings to this store. The gate refuses an absent snapshot.
An arbitrary nonempty ID is not project verification: the future caller must
resolve a host-owned project record and root before calling the selection API.

Before implementing IPC, the independent service must own this sequence:

1. Authenticate the host connection under independent identities and resolve a
   registered project root. Reject missing/unverified identity or project.
2. Parse the actual operation at dispatch, resolve paths including symlinks, and
   derive root/screen/preset facts itself. Risk booleans from model JSON or the
   application are not proof. No native command adapter is connected yet.
3. Prepare an expiring challenge binding a random service nonce, connection,
   operation/canonical arguments, session/project/root, context revision and
   relevant build/install digests. Return immutable review content.
4. Obtain the local decision for that exact challenge. A UI Boolean or unkeyed
   fingerprint is not an IPC credential and must never alone authorize execution.
5. Authenticate and revalidate the decision and live facts, then atomically spend
   the nonce before executing. Changed files/digests/context, expiration,
   disconnect, denial, cancellation or replay invalidate it. Retrying requires a
   new challenge. Service restart invalidates outstanding challenges.

No socket, service identity, signing credential, challenge transport or service
ledger has been implemented. Until those boundaries can be compiled and tested,
all side-effecting native tools remain unregistered/unavailable. This protocol
outline must not be described as a connected service or replay protection.

## Implemented in source

- `MinisApelinBuiltInSkills.swift` embeds the 14 upstream built-in skills,
  companion files and the pinned project JSON schema without depending on
  ApelinProject or KWWK modules.
- `MinisApelinTools.swift` defines `apelin_skill_list`, `apelin_skill_read`,
  `apelin_host_environment` and `apelin_integration_status`. The native host
  environment tool reads ProcessInfo OS version and compile-time architecture/
  simulator conditions directly in the app; it does not discover toolchains,
  contact services or infer build readiness. Skill reads resolve only exact listed names,
  supported legacy aliases and exact companion filenames; they do not read
  arbitrary filesystem paths.
- The chat tool definitions and concurrent dispatcher register these tools.
  Both new Swift files are referenced by the Xcode project and Sources phase.
- `MinisDevelopmentApprovals` adds a separate MainActor queue of suspended
  requests, bound to session, project, tool, canonical JSON arguments, directory
  and optional build-description digest. Request IDs and fingerprints must match
  to resolve once; task cancellation denies the matching request and rechecks
  cancellation after resumption. There are no session-wide grants.
- The existing permission sheet entry point now presents either offload or
  development requests, showing the full development context with Allow Once /
  Deny actions. Dismissal callbacks capture their presented request ID.
  No native executor calls this queue yet. A partial `MinisDevelopmentPolicy`
  now covers integration reads, native command/root/preset facts, screen read/action,
  force push and remote reset; unsupported operations deny. The four integration
  reads pass an exact-name adapter at the actual host dispatcher. Other adapters
  are not connected. `authorize` joins policy and queue, refuses unavailable
  backends, and invalidates approval if the trusted context revision changes.
  It does not mint service authorization tokens. User-selectable modes, complete
  upstream policy parity and service authorization remain unavailable.
- `AIChatViewModel+Cancel.swift` cancels development requests for the current
  session when Stop ends the run or a model change terminates a retrying run.
  Healthy in-flight model switches retain the host's existing behavior.
- The dispatcher explicitly returns an unsuccessful unavailable-backend result
  for unimplemented apelin_ tool names. They are never substituted with iSH
  commands or an installed application's service. This is refusal, not execution.
- `scripts/check_development_policy.py` extracts the production Swift policy and
  compiles a truth table with 42 verdict checks and exact tool-name checks. It
  uses no Python policy reimplementation. On this device it returned exit 2:
  swiftc is unavailable, so no Swift check ran. On iOS it requires a reviewed
  Tool.entitlements path via MINIS_POLICY_ENTITLEMENTS and signs before launch.
- Integration status reports `backendConnected: false` and explicitly lists
  the unavailable development capabilities. Existing shell and file tools
  continue to use iSH/Alpine.

This is source integration, not a verified running application. No new tool has
been executed inside a compiled OpenMinis build on this device.

## Module map

| Capability | Upstream source location | OpenMinis integration status |
| --- | --- | --- |
| Built-in skills | `vendor/apelin/Packages/ApelinAgent/Sources/ApelinAgent/Skills` | Generated documents and four read-only integration tools are wired in source; runtime untested |
| Agent tools and authorization | `vendor/apelin/Packages/ApelinAgent` | Independent per-call approval queue and sheet in source; policy, native dispatcher and service-side verification not connected |
| IPC and independent service | `vendor/apelin/Packages/ApelinKit/Sources/ApelinProtocol`, `vendor/apelin/Shared/Protocol`, `vendor/apelin/Apelind` | Not connected; independent identities and service setup remain to be implemented |
| Toolchains and SDKs | `vendor/apelin/Packages/ApelinKit/Sources/ApelinEnvironment`, `vendor/apelin/Packages/ApelinToolchain` | Source imported only |
| Project descriptions and templates | `vendor/apelin/Packages/ApelinKit/Sources/ApelinProject`, `vendor/apelin/Extensions/Development` | Schema embedded as skill companion content; no project/template backend |
| Native shell and filesystem | `vendor/apelin/Packages/ApelinKit/Sources/ApelinConsole`, `vendor/apelin/Packages/ApelinToolHost` | Not ported; existing host operations still use iSH |
| Build and packaging | `vendor/apelin/Packages/ApelinKit/Sources/ApelinBuild` | Source imported only; no external build entry point |
| Diagnostics | `vendor/apelin/Packages/ApelinDiagnostics` | Source imported only; no log, crash or load-confirmation backend |

Locations identify the upstream code to review, not independent runnable
components or completed ports. Build/sign/install and device-test integration
still require following the tool host/protocol call chains into their service
implementations and validating authorization before execution.

## Reproducible source checks

From the repository root:

```sh
python3 scripts/generate_apelin_skills.py --check
python3 scripts/check_apelin_build_environment.py
```

The generator check compares the generated Swift and SHA256 manifest with the
vendored inputs; it passed during integration. To deliberately regenerate after
reviewing changes to the pinned inputs, run the generator without `--check`.
The source manifest is `docs/apelin-skill-sources.json`.

The environment audit is read-only and returns 2 when prerequisites are missing.
Its result describes prerequisite presence, not a successful compile, dependency
compatibility assessment, signing check or package validation.

The tool constructor signatures, registration and dispatcher have been inspected
against the host sources. Swift type checking, Xcode project parsing and runtime
execution remain unverified. The device's `plutil -lint` invocation emitted an
error despite exiting zero, so it is not evidence of a valid Xcode project.

## Build environment and remaining work

`BUILDING.md:79` specifies iOS 26.2 and Swift 6.0. The Xcode project-level
configurations also set 26.2/6.0, while the main app target explicitly overrides
them with iOS 16.0 and Swift 5 language mode. These values coexist in the upstream
HEAD; the integration diff only adds Swift file references and does not lower any
deployment target. The widget targets iOS 16.2 and is a main-app dependency;
packaging and installation on iOS 16.1.2 require checking this separately. Swift
language mode does not establish that a compiler can build every upstream dependency.
A read-only sample of local historical tags found the same mixed deployment
values in `0.22-preview`, `1.12` and `1.15`. The earlier `0.1-preview`,
`0.10-preview` and `0.20-preview` trees contain no `project.pbxproj`, so they do
not establish an available older iOS-compatible host. No compatible earlier
release has been demonstrated and no features have been removed.
Some host sources also reference iOS 26 APIs, which SDK 17.4 cannot compile simply
because runtime availability guards are present.

The current device has a working CLT 15.3 C/Objective-C toolchain and SDK 17.4.
The available Apelin toolchain catalog does not provide a compatible Swift 6.1
build route for this iOS 16.1.2 host. This does not mean C/Objective-C development
is unsupported. Do not repeatedly query or force-install incompatible Swift
releases to work around this constraint.

The environment audit also found missing iSH libraries and headers, Rclone
framework, Alpine rootfs resource and LAME library, as well as an uninitialized
iSH submodule. Full dependency preparation and a suitable Swift/Xcode build
environment are still required. A macOS build route needs a reviewed build and
packaging entry point; it has not been configured or exercised here.

The following integration work remains: independent privileged backend and IPC;
Strict/Relaxed/Full authorization at dispatch sites; toolchain and SDK management;
templates; native iOS commands and jailbreak filesystem access; build, signing
and installation; system logs and crash symbolication; load confirmation; and
device testing. The current offload permission mechanism is not evidence that
these independent backend operations are authorized correctly.

`apelin-project.json` is an external workspace declaration without a build script.
There is no successful full build, signed app, installed integration or release
package yet. Declare and review a real external build entry point before using
`apelin_project_build` to produce packages. Do not repackage upstream binaries as
if they were a compiled port. Final distribution requires separate rootless and
roothide release builds and validation, with permanent package/app identifiers
settled before the first installation.

## Licensing

Retain OpenMinis's GPLv3 obligations for the combined distribution and Apelin's
MIT license and attribution in `vendor/apelin/LICENSE`. Preserve the licenses of
all bundled dependencies. Source provenance and dependency licenses are part of
the release review, not proof that a release has been built.
