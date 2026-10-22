# vnodebypass frontend (rootless arm64)

## Integration

- `App.m` is the complete App executable, including `main` and AppDelegate.
- `VBModule.m` is the complete CC bundle implementation. Keep NSPrincipalClass
  `VBModule`, executable `VBModule`, and existing VBModule.bundle Info.plist and
  `enabled` / `disabled` image assets. It implements CCUIContentModule directly
  with a UIKit UIButton, not the automatic CCUIToggleModule toggle path.
- `CCCompat.h` contains minimal Theos protocol declarations, verified against:
  https://raw.githubusercontent.com/theos/headers/master/ControlCenterUIKit/CCUIContentModule-Protocol.h
  https://raw.githubusercontent.com/theos/headers/master/ControlCenterUIKit/CCUIContentModuleContentViewController-Protocol.h
- `TouchGate.h` requires a real ended UITouch inside the control. A missing
  UIEvent, a programmatic sendActionsForControlEvents:, setSelected:, module
  initialization, layout, foregrounding and notifications cannot issue writes.
- `../shared/Frontend.h` includes implementation when
  VB_FRONTEND_IMPLEMENTATION is defined. Define it once per executable/bundle;
  App.m and VBModule.m are separate binaries and must not be linked together.
- App bundle ID is `kr.xsf1re.vnodebypass.next` (App-Info.plist).
- Dependencies: iOS SDK UIKit/Foundation/CoreFoundation, libobjc, libSystem;
  runtime CCSupport for loading the CC bundle. No kernel library, NSTask,
  shell, LSApplicationProxy, private CC superclass or external downloaded header
  is required. Persona APIs come from libSystem and must be permitted by the
  jailbreak's launch/signing policy. Do not run the App as root as a substitute.

## Build

```
sh project/ui/build-check.sh /var/minis/workspace/vnodebypass-fix/iPhoneOS16.5.sdk /tmp/vb-ui-build
```

The script runs ARC arm64 compilation with -Wall -Wextra -Werror (only unused
parameter warnings disabled), links the App and dynamically looked-up CC bundle,
and stages the App plist. Outputs are unsigned. Signing/entitlements and icon
resource copying remain the packager's responsibility. This SDK lacks the
libobjc.tbd/libSystem.tbd aliases, so the linker uses -lobjc.A -lSystem.B.
Only project/ui and project/shared/Frontend.h were created by this frontend task.

## Behavior

All status/enable/disable commands spawn the fixed helper path
`/var/jb/usr/bin/vnodebypass` with persona 99, UID 0, GID 0, passing `&attr`.
All attr/file-action/spawn errors are checked. The child has stdout piped,
stdin/stderr redirected to /dev/null, and a minimal environment. Stdout is
fully drained before waitpid, then parsed strictly as an XML plist dictionary
with validated state/message/counts, even if exit status is nonzero. There is
no fallback to another executable or guessing state from bash/file presence.

One background serial queue handles all process I/O; all UI/state publishing
uses the main queue. Both frontends read current state only from helper status.
An explicit write is followed by a fresh status query and a Darwin notification
`kr.xsf1re.vnodebypass.next.statechange`; notification handlers only query status.
No timer, automatic enable, startup recovery or automatic disable is present.
A long-running helper leaves the UI busy until it completes; the frontend does
not forcibly kill an in-progress privileged operation.

The App shows current state/counts/message, two explicit enable/disable buttons,
and a query-only refresh button. Enable is available only after a successful
status=disabled response, and requires an explicit global-hide warning confirmation.
Disable remains available for mixed/legacy/error states, but never runs without
an explicit user action. Foregrounding only queries.

CC opening queries status. A true touchUpInside displays the current state and
explicit action sheet (UIAlertController alert style). It never toggles from
setSelected:. Enabling requires confirming the displayed global-hide warning;
closing/querying require their own explicit action. The normal CC tile is
therefore not a blind one-tap toggle. setSelected: is presentation-only and
ignores the value supplied by SpringBoard. Existing icon resources are loaded
from the module bundle, with SF Symbols used only if resources are absent.

## Validation

Both .m files compiled warning-free and linked successfully as arm64 Mach-O
against the local iPhoneOS16.5 SDK using clang 19/ld64.lld on Alpine. This is not
a live SpringBoard or privileged-helper test. Device tests still required:

1. Add/reload/reorder the CC module and call setSelected: both ways: no writes.
2. Open CC / foreground App / post statechange: helper status only.
3. Cancel enable confirmation: no enable command.
4. Explicit enable/disable: exactly the selected command, then status; render
   helper output rather than optimistically flipping selection.
5. Missing helper, denied persona, nonzero exit with XML, invalid XML,
   mixed/legacy/busy states: readable error/status, no automatic recovery.
6. Check CC UIAlertController presentation and glyph layout on the target
   SpringBoard/CCSupport version, particularly iPad and compact tile sizes.
