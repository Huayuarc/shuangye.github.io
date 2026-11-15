# Toolchain and SDK Compatibility

SDKs can be downloaded or imported independently of the installed toolchain
and the device's OS. Import checks identity, contents, paths and integrity;
it does not reject an SDK just because no current compiler can use it.
Compiler/SDK compatibility is checked when selecting a build environment.
The SDK version is neither the compiler's host requirement nor the output's
minimum deployment target. An older SDK can build a program that requests a
newer minimum OS using the older API surface; the project check warns about
that limited API surface instead of rejecting the pairing.

The installation catalog carries each release's CPU requirements, recommended
SDK, verified SDKs and the basis of its Swift host limit. It uses the kernel's
`hw.optional.arm.FEAT_*` values, not a device-name whitelist. Toolchain setup
prefers the recommended SDK when available, and otherwise the newest compatible
installed or downloadable one. The existing on-device self-test still checks
that an installation works; incompatible CPU instructions are rejected before
starting a compiler.

## CPU Coverage from iOS and iPadOS 16

The oldest supported **iPhone** CPU is A11. The oldest supported **iPad** CPUs
are A9/A9X; iPadOS 16 still supports the fifth-generation iPad and the first
iPad Pro. The following groups therefore cover the entire supported floor,
including chips that cannot run an unmodified Apple Silicon compiler.

| CPU family | Relevant features | Available Apple CLT base component | Swift CPU compatibility |
|---|---|---|---|
| A9 / A9X | none of LRCPC, SHA3, DotProd | none | none |
| A10 / A10X | none of LRCPC, SHA3, DotProd | none | none |
| A11 | no LRCPC | none | none |
| A12 / A12X / A12Z | LRCPC | every reviewed release, for C/C++/Objective-C; modules are release-specific | 14.2, 15.0 and 15.3 run (measured on an A12Z); 27.0 does not |
| A13 and later | LRCPC, SHA3, DotProd | every reviewed release | 14.2, 15.0, 15.3 and 27.0, subject to their system requirements |
| M1 and later iPads | LRCPC, SHA3, DotProd | every reviewed release | same as A13 and later |

CLT 16.4 and 27.0 additionally need the system C++ runtime to export
`__libcpp_verbose_abort`. It is absent from the 16.1 and 16.2 SDKs and present
in 16.4; installation checks the actual system symbol rather than guessing
a minimum OS from that interval. On a system without it, choose CLT 15.3
or earlier. A compatible CPU alone is insufficient.

These are instruction-set conclusions, not claims that every device and OS
combination has been run. `arm64` alone is not sufficient: the tools contain
LRCPC instructions that A9–A11 cannot execute. Raising their iOS version cannot
add those instructions. New chips are evaluated by their reported features.

The static inventory describes the host images selected by Apelin, including
loaded libraries and Swift plugins, and excludes iOS target runtime archives.
An instruction in a guarded or unused path is recorded but is not automatically
a requirement of every operation. In particular, base compilation, Clang
modules and Swift have separate requirements. Machine code is never patched
to emulate missing CPU instructions.

Primary references: [Apple's iOS/iPadOS 16 device list](https://support.apple.com/en-tm/103267),
[LLVM's Apple CPU feature definitions](https://github.com/llvm/llvm-project/blob/main/llvm/lib/Target/AArch64/AArch64Processors.td),
and [XNU's feature sysctls in the iOS 16 generation](https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.61.2/bsd/kern/kern_mib.c).
Device evidence is kept in [Device-Validation](Research/Device-Validation.md).

## Swift Versions

| CLT | Swift | Minimum host offered | CPU features required | Matching SDK | Verified cases |
|---|---|---|---|---|---|
| 14.2 | 5.7.2 | iOS 17.3.1 | LRCPC (A12 or later) | 16.2 | ordinary Swift, dylib/client, async; arm64 + arm64e |
| 15.0 | 5.9 | iOS 17.3.1 | LRCPC (A12 or later) | 17.0 | the above plus Observation macros; arm64 + arm64e |
| 15.3 | 5.10 | iOS 17.3.1 | LRCPC (A12 or later) | 17.4 | the above plus Observation macros; arm64 + arm64e |
| 16.4 | 6.1.2 | not offered | — | — | its swift-driver imports macOS's zippered availability check: dyld stops it on iOS 17.3.1 and iPadOS 26.0.1 |
| 27.0 | 6.4 | iOS 26.0 | LRCPC + SHA3 + DotProd (A13 or later) | 27.x | ordinary Swift, dylib/client, async and Observation macros; arm64e |

| Device tested | 14.2 / SDK 16.2 | 15.0 / SDK 17.0 | 15.3 / SDK 17.4 | 16.4 / SDK 18.5 | 27.0 / SDK 27.0 and 27.1 |
|---|---|---|---|---|---|
| vphone 26.6.2 | 12/12 | 14/14 | — | — | 10/10 with each SDK |
| vphone 27.0.1 | 12/12 | 14/14 | — | — | 10/10 with each SDK |
| 15 Pro, iOS 17.3.1 | 12/12 | 14/14 | 14/14 | swiftc not loaded (missing symbol) | refused before execution: host version |
| A12Z, iPadOS 26.0.1 | 12/12 | 14/14 | 14/14 | swiftc not loaded (missing symbol) | refused before execution: SHA3 / DotProd absent |

Counts include the six C-family cases. Swift 5.7 has no macros; the iOS 27
SDK exposes Swift interfaces for arm64e only. The 15.x compilers carry two
SHA3 instructions, in BLAKE3's hash_many (compile caching) and in the
symbol-graph edge set (`-emit-symbol-graph`), neither of which an Apelin
build reaches; every Swift case passed on an A12Z without SHA3. 16.4's and
27.0's swift-frontend also hash modules with XXH3 (SHA3) and use DotProd.
CPU features, rather than the device's marketing name, decide availability.

## Choose a Toolchain

These choices follow the recorded component requirements; they do not change
existing project bindings or claim additional device tests.

| Device and host | Suggested pairing |
|---|---|
| A9/A9X, A10/A10X, A11 | No currently supported Apple CLT; the IDE itself still works |
| A12/A12X/A12Z | CLT 15.3 + SDK 17.4 for C-family and Swift 5.10 (iOS 17.3.1 or later); CLT 14.2 + SDK 16.2 for Clang modules |
| A13 or later / M-series, below iOS 26 | CLT 15.3 + SDK 17.4 for Swift on supported hosts; CLT 27.0 + SDK 27.0 for C-family projects when its required C++ runtime symbol exists, otherwise 15.3 + 17.4 |
| A13 or later / M-series, iOS 26 or later | CLT 27.0 + SDK 27.0 for C-family and Swift; SDK 27.1 is also verified |

## C, C++ and Objective-C

Each of these versions passed six cases on all four recorded devices: C, C++ and
Objective-C, each for arm64 and arm64e. All require LRCPC. On a CPU without
SHA3, clang modules have no extra CPU requirement for 14.2; the remaining
releases require ordinary headers without `-fmodules` / `@import`.

| CLT | Newest readable SDK | Swift |
|---|---|---|
| 27.0 | 27.x | 6.4 |
| 16.4 | 18.5 | not offered |
| 15.3 | 17.4 | 5.10 |
| 15.0 | 17.0 | 5.9 |
| 14.2 | 16.2 | 5.7.2 |

CLT 12.4 is unavailable because its arm64e C++ output fails the runtime
check. 16.2, 14.3, 13.4, 13.2 and 12.5 passed on every device and were
dropped on 2026-10-21: a kept release reads every SDK they read. Setup
refuses them by name and the download list leaves them out. A11 and earlier are refused before toolchain installation. Newer
SDKs are refused when their headers or linker stubs exceed a CLT’s limit.

## Verified SDK Downloads

These are the actual C-family pairings exercised in the SDK matrix, not
an exhaustive test of every CLT × SDK combination. Each row passed six
cases on all four devices. Swift uses the matching SDKs listed above.

| iPhoneOS SDK | CLT used for C-family validation |
|---|---|
| 14.5 – 16.2 | 14.2 |
| 16.4 – 17.0 | 15.0 |
| 17.2, 17.4 | 15.3 |
| 17.5 – 18.5 | 16.4 |
| 18.6 – 27.1 | 27.0 |

On 2026-10-21 every one of the 23 SDKs was also imported again on an
iPhone 15 Pro (iOS 17.3.1) and built against with CLT 27.0, which reads them
all: a C++ program, the CLI template and the tweak template's dylib, run
and loaded there.

The default source contains these 23 complete SDKs. SDKs 13.0–14.4 are
excluded because their source trees lack the C++ standard-library headers.
The SDKs themselves are unchanged. This matrix covers roothide; a rootless
end-to-end device run and an iOS 16 physical host remain untested.

## Where the data lives and how to update it

`CommandLineToolsSupport.releases` in
[`Support.swift`](../Packages/ApelinToolchain/Sources/ApelinToolchain/Support.swift)
is the single maintained release table. It records Apple product IDs and
whole-package SHA-256 values,
recommended and verified SDKs, component CPU requirements and Swift host
requirements.
A newly published product with an old version number is not silently treated
as the reviewed binary. After download, a changed package digest is refused
before extraction.

[`Compatibility.swift`](../Packages/ApelinToolchain/Sources/ApelinToolchain/Compatibility.swift)
turns that table into versioned data. The `compatibility` member is returned
by `toolchainCatalog`, saved in the generated toolchain `manifest.json` and
in the registered `ToolchainRecord`, and preserved when the build worker
reads the registry. Existing records without it still decode. Existing
`newestSDK`, `swiftRequirements` and `clangModuleCPUFeatures` fields remain
available to current clients. The app's interface is unchanged.

- `minimumHost` and `cpuFeatures` describe the base compiler host.
- `requiredLibcxxSymbols` names required symbols in the fixed system C++
  library. Missing symbols disable the release before any compiler runs.
- `recommendedSDK` / `verifiedSDKs` describe build inputs, not host OS limits.
- `swiftMinimumHostBasis` distinguishes a runtime-semantic requirement from
  the conservative `verified-policy` floor used for legacy Swift.
- `swiftVerifiedHosts` records actual device runs separately from that policy.
- `systemSymbolSDK` / `systemSymbolCount` record a static SDK export check;
  they do not claim a device run or establish the oldest possible OS.
- `staticInstructionFeatures` is the whole-image inventory of selected ISA features, including guarded
  paths; use the component requirements to decide which operation is available.

To inspect the table without a device or network request, run
`apelin-toolchain-probe compatibility`. To review a new Apple package:

1. Verify its source identity and digest, then prepare a static inventory with
   the opt-in `StaticInventoryTests` test. Set `APELIN_STATIC_PACKAGE` to the
   downloaded package, `APELIN_STATIC_VERSION` to its release, and
   `APELIN_STATIC_WORKSPACE` to a new private output directory. The test uses
   Apelin's own dependency selection, retains arm64 host images and never
   executes or installs them.
2. Run `Scripts/inspect-toolchain-imports.py <workspace>/host-images
   --instructions --cpu apple-a12 --cpu apple-a13`. It verifies image digests,
   lists strong/weak system imports, and compares full LLVM decodes. It builds a
   small local helper using Xcode's LLVM C API to count instructions without
   formatting huge disassembly files. The inspected code is never executed. A reference
   decoder's unknown instruction or missing address is an incomplete audit,
   never a pass. `--cpu` is repeatable; it also enables the instruction scan.
3. Review missing instructions by component and path. Separately check system
   imports, Swift ABI/OS-dependent behavior, linker stub formats, SDK headers,
   Swift interfaces and macro plugins. Finding that the CPU can decode a
   compiler does not prove that its runtime dependencies are available.
4. Add the product and its evidence to the table. Preserve the actual verified
   host/SDK history; do not replace it with a guessed minimum. A new compiler
   or recipe still goes through setup's integrity and functional self-tests.
5. Run `make check` and `make harness`. The harness also verifies the static
   auditor against synthetic LRCPC, SHA3 and DotProd instructions, without
   executing them.
