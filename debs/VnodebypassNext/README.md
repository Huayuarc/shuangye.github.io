# Vnodebypass-next 0.4.7-Next-fix2 — experimental repair candidate

## What this is
A source-level reconstruction of the uploaded rootless package, with rewritten
App/CC frontends and a unified helper. It is not a byte-for-byte rebuild of the
uploaded binary. Baseline and hashes: `PROVENANCE.json`.

Only Dopamine **rootless iOS 15–16 / iphoneos-arm64** is targeted. The inherited
kernel offsets have NOT been verified on this user's exact device/OS. Do not
install this package on RootHide. The Makefiles intentionally force rootless;
CI's second scheme pass may rebuild the SAME arm64 package, not a RootHide port.

## Changes
- App and CC use the same structured helper `status`; no bash-existence guess.
- CC state setters, layout, loading and foreground events never enable/disable.
  Only a real touch and an explicit action/enable confirmation do so.
- Persona attributes are passed to spawn; spawn/wait/child exit errors are read.
- Background serial process execution, main-thread UI, cross-process refresh.
- No unlink/symlink of `/var/jb`, no embedded kernel backend in App or CC.
- Root-owned journal, process lock, boot-session validation, explicit error states.
- Interrupted preparing/restoring operations are fail-stop: never guess whether
  a reference decrement already happened. Preserve the journal, fully reboot
  the device (NOT merely respring/userspace restart), then re-jailbreak.
- Verified write results and visibility-bit readback. Entire visibility restore
  completes before any reference release.
- Protocol stdout isolated before backend loading; dependency logs cannot prefix
  XML replies.
- Conservative 55-path subset of the uploaded 290 entries; removed duplicates,
  bootstrap roots, system libraries/configuration, SSH, package databases,
  injection directories, live preferences and broad shared parents. Exact
  removals: `PATH_AUDIT.json`. No new unverified hiding paths were added.
- Compiled-in path whitelist and held-descriptor path/type recheck.

## Important limits
The inherited primitive changes shared vnode flags and manually adjusts vnode
reference counters using non-atomic kernel read/modify/write. The process lock
only serializes this helper, NOT XNU. Checked writes and journals do not make
those operations atomic; kernel panic, races, leaked references and a full
reboot remain possible. This is an EXPERIMENTAL candidate, not a proven stable
release or a guarantee of compatibility/detection bypass.

Hiding is global, not per-app. Even cache/app paths can affect their owning
applications. Existing processes may keep mappings/descriptors; that is not a
proof of hiding consistency. The narrower list deliberately trades coverage for
compatibility. This is not comprehensive detection bypass; loaded-image, URL,
process, code-signing and remote risk checks are separate mechanisms.

`status` does NOT modify visibility flags or reference counters. It MAY create
root-only metadata directory/lock and initialize the KRW backend to read an
existing same-boot session. It is not a promise that every external KRW library
performs no internal initialization writes. Counts cover this helper's session,
not all hidden objects from other software.

## Upgrade / rollback
1. In the ORIGINAL version, explicitly disable hiding while it still works.
2. Fully reboot, then re-jailbreak using Dopamine. Confirm normal plugins work.
3. Install the repair candidate; restart userspace once to unload the old CC
   binary. Never mix old helper/App/CC with the new protocol.
4. First test ONLY opening/closing App and CC without touching enable. State
   must remain disabled. Test CPUthermal/other affected plugins in this state.
5. Explicitly enable once, compare App/CC counts, explicitly disable, check both
   return to disabled and other plugins remain normal.
6. If an interrupted/error/legacy state appears, preserve the journal and fully
   reboot. Do not delete the journal and retry raw kernel addresses.

preinst blocks known legacy journals; prerm attempts new-protocol disable before
removal and stops on error. Old-package upgrade scripts may delete files before
new preinst runs, so the clean reboot baseline is especially important. No
script deletes a running session journal to force an upgrade.

## Build and validation
- Theos: `make THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1 package`.
- Local cross-check: `sh build-local.sh`, with `SDK` and `LDID` paths set.
- Sources include all build files, resources and relevant upstream primitive
  code; exclude build/, .theos/, packages/ and repository metadata in delivery.
- Compilation/static tests/package audit are NOT target-device verification.
- Device acceptance still required: idle CC/App no actions; canceled confirm;
  App↔CC sync; rapid/concurrent taps; enable/disable cycle; plugin coexistence;
  helper error/legacy journal; full reboot and fresh jailbreak.
