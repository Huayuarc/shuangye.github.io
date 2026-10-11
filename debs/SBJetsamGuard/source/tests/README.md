# SBJetsamGuard host regression and independent review

## Contract and execution

- 限额策略为 1024 / 2048 / 4096 MiB，默认 2048 MiB；仅将低于目标的正数 SpringBoard 限额提高到用户选择值，已有更高限额与非正特殊值保持原样。4096 MiB 可能挤压其他进程，不增加物理 RAM。

Run from any working directory:

```sh
sh source/tests/run.sh
CC=clang sh source/tests/run.sh
```

Only C11 compiler, POSIX shell and mktemp are required. Stub headers are test-only via `-I tests/stubs`. The released Makefile compiles main.m and ScriptFeatures.m; main.m includes main.c for shared identity/apply/status routines. These host tests exercise the C baseline, not the full Foundation/notification/Prefs runtime. The integration test includes main.c, renames all external OS entrypoints and executes no real libproc/memorystatus/kqueue/sigaction/sysctl/close calls. sigemptyset only initializes a local mask. Test executables are created under mktemp and removed on exit. No runtime binaries or logs belong in the Source zip; include this entire tests/ directory recursively.

Result after stop-request fix on Alpine aarch64: **2,023 policy assertions, 46 integration scenarios / 884 assertions, all PASS.** Four additional named risks are deliberately reproduced in the C baseline; PASS characterizes behavior rather than proving these races absent. The shipped main.m checks event registration, marks unavailable exit events, uses a 15-second fallback, and returns 71 on fatal kevent failure; the latter two baseline findings do not describe its release event loop. The PID-only non-CAS write races remain and are documented. The stop-during-enumeration case now verifies zero writes.

## Coverage

- RAM below supported threshold, exact 2/3/4/6/8 GiB, floor rounding and UINT64_MAX; 324 active/inactive value and valid-attribute combinations; all 31 unknown attribute bits; policy idempotence; struct size/field offsets; equality detects every field change.
- Process enumeration zero/negative/too-large size, invalid returned count, partial trailing PID, pid <= 1 filtering, exact executable path rather than basename/prefix, uid 501, truncated proc info, absent executable path.
- Start-time identity rechecks; cmd8/cmd7 arguments and size; two prewrite reads; concurrent-property change returns EAGAIN; read/write error propagation; success verification; failed/mismatched verification stops further writes; no-op/high/nonpositive limits.
- At most four total apply attempts for one observed identity, transient versus terminal errors, 5-second retry / 60-second completed waits, identity change (same PID or new PID), NOTE_EXIT and retry budget reset.
- Root guard, missing symbol/sysctl/RAM/kqueue failures, argument rejection, status read-only mode, EINTR continuation, SIGTERM helper-only handling and absence of restore/downward cmd7.

## Findings and recommendations

### 1. High residual race: cmd7 is keyed only by PID

`apply()` checks identity, reads properties, rechecks identity, reads properties again, then calls cmd7. The process can exit and its PID can be reused between the final check and cmd7. The deterministic mock changes the process generation at the cmd7 boundary: cmd7 still writes to the replacement, and only the postwrite check returns -2. UID/path matching is not guaranteed atomically for the process written to. Adding one more identity check narrows but does not close this gap: XNU's public/private command here resolves PID with proc_find, not a pid+unique-id compare-and-set.

The same GET-to-SET interval permits another manager to raise a limit to 4096 MiB and then be overwritten with our 1024 MiB snapshot. Therefore 'never lowers a limit' is an observed-snapshot policy, not an unconditional atomic guarantee. Avoid claiming race-free or never-kills-SpringBoard behavior. If the product requires an absolute guarantee, this PID-only non-CAS interface cannot supply it.

### 2. Medium: event registration errors ignored

`kevent(EV_ADD|EV_ONESHOT)` return is discarded. On ESRCH/EPERM/resource failure, writes can still proceed and the helper sleeps 60 seconds after completion with no NOTE_EXIT subscription. Polling eventually recovers, but the advertised exit-driven responsiveness is not guaranteed. Check add return; for transient registration failure retry under the same bounded budget or explicitly enter a short-poll fallback; treat fatal errors as nonzero helper exit. Check returned event ident/filter/generation when processing exit events as defensive hardening.

### 3. Medium: fatal wait error exits successfully

Non-EINTR wait error breaks the loop, closes kqueue, returns 0. daemon.plist uses KeepAlive.SuccessfulExit=false, so launchd will not restart the helper after this abnormal stop. Distinguish requested shutdown (0) from event infrastructure failure (e.g. 71). Mock EBADF deterministically reproduces the successful-exit bug.

### 4. Low: stop request during enumeration still allows a write

Only the loop entry and the point after apply inspect quitting. A SIGTERM while find_sb/identity is executing can be followed by a new cmd7. The mock raises the helper's own stop flag in the first info callback and observes one write. Check quitting before initiating apply and again immediately before cmd7; do not use SpringBoard signals. This does not reintroduce restore or make stop lower limits.

### 5. ABI semantic caveat: GET does not expose raw nonpositive defaults

XNU 8792.61.2 kern_memorystatus.c:7385-7418 converts stored <=0 active/inactive values through task_convert_phys_footprint_limit(-1, ...). Therefore cmd8 can return a positive effective/default limit for a raw nonpositive setting. `sjg_plan` correctly preserves nonpositive **returned** values, but cannot promise to preserve invisible raw default/unlimited state; exact restoration of that raw state would also be impossible from the GET snapshot. Unknown attribute bits are fail-closed, matching the referenced kernel's accepted mask 0x1.

The SDK ABI otherwise matches the downloaded XNU headers: proc_info.h PROC_ALL_PIDS=1, PROC_PIDTBSDINFO=3; proc_bsdinfo size 136 with start sec/usec at offsets 120/128 for 32-bit uid_t/gid_t on Darwin arm64; memorystatus command 7/8 and v1 fields signed32,unsigned32,signed32,unsigned32 at offsets 0/4/8/12, size 16. GET accepts 16 or v2 size, SET requires exactly 16. Host mock compilation does not substitute for the real iPhone SDK/Theos build or device entitlement validation.

## Stop/uninstall safety decision

The earlier restore implementation would call cmd7 with lower old values if identity/current-properties matched. It did not check actual footprint. XNU kern_memorystatus.c:7666-7713 writes the selected active/inactive limit to task footprint ledgers with its fatal bit. Lowering below current consumption can make SpringBoard immediately/soon eligible for fatal limit enforcement, producing precisely the unwanted desktop restart/false logout. The downloaded files do not include the task/ledger enforcement implementation, so an exact scheduling/instant-kill guarantee cannot be inferred from them alone; the enforcement risk is sufficient to reject live-process restore.

A proc_pid_rusage(RUSAGE_INFO_V0).ri_phys_footprint gate would only sample consumption; footprint/state can grow or switch between sample and cmd7, and a safety margin cannot close the PID/GET-to-SET races. It is a risk reducer, not a no-kill guarantee. **Prefer the adopted contract: never proactively lower the living SpringBoard on uninstall or helper stop, do not restart/kill it, and let normal process replacement reset per-process policy.** Regression checks SIGTERM leaves the raised active/inactive values unchanged and performs only the original upward cmd7.

No reviewed main.c or Policy.h changes were made by this reviewer. Main changed during review only by the delegating agent's removal of restore.

Reviewed final baseline SHA-256:

- main.c: 417ec74d824f4da39892e5b5313fe45e5eed96a3fa62c6006e11d1da9842926d
- Policy.h: 711353848f5eef13cbc7d5cdae1466426fbc367c5c719c3bf5fe3e0341122c54
