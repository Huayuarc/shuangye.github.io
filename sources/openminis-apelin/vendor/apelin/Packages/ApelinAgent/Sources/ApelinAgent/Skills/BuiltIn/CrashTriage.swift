extension BuiltInSkills {
    static let crashTriage = SkillDocument(
        name: "apelin-crash-triage",
        description: "When the target crashes or resprings after an install: find the report, symbolicate it against this build's dSYM, read it before changing code.",
        body: """
        # Crash triage

        A crash is read before anything is changed.

        1. `apelin_crash_list` for the target process (SpringBoard, the hooked app),
           newest first. A respring loop shows several close together. Reports
           appear a moment after the crash, and some arrive with a `.synced`
           suffix: list again if the one you expect is not there yet.
        2. `apelin_crash_symbolicate` with the report id and the `buildID` you
           installed. The host matches the report's image UUID to the project's
           dSYM; if `matchedImageUUID` is empty, the report is from another
           build: rebuild, reinstall and reproduce instead of reading stale
           frames.
        3. Read the crashed thread top down. The first frame in your image is
           where to look; frames above it in system code tell you what your code
           passed in. `suspects` ranks images by blame; your tweak first is
           likely, but a system frame on top is common for a bad argument. A
           tweak dylib (in `DynamicLibraries` or `TweakInject`) on the faulting
           thread or the exception backtrace is what blames it, not its mere
           presence in the image list.
        4. `apelin_crash_read` for the exception type, the termination reason and the
           other threads when the crashed thread is not enough.
           - `EXC_BAD_ACCESS` / `KERN_INVALID_ADDRESS`: a released object, a
             wrong ivar or method signature, a hook on the wrong class. On
             arm64e a raw read of a signed-pointer ivar faults at a very large
             address; strip it with `ptrauth_strip` before dereferencing.
           - `EXC_BREAKPOINT` / `SIGTRAP`: a Swift runtime trap or an
             `NSException`; the last exception backtrace names it.
           - `unrecognized selector`: the class or OS version lacks the method
             you called; check with `apelin_sdk_analyze_framework` and guard it.
           - Termination reason `FRONTBOARD` / watchdog: the main thread was
             blocked. A tweak that waits in its constructor or on the main
             thread of SpringBoard does this (apelin-tweak-development).
        5. `apelin_log_read` for what the tweak logs: the log is live and holds no
           history, so it hears only what happens while it listens (the
           apelin-tweak-runtime skill); ask the user to reproduce during the call.
        6. Fix, rebuild, reinstall, respring, then `apelin_package_confirm_loaded` and check
           that no new report appears.

        If SpringBoard keeps crashing, the safest step is `apelin_package_remove` with
        this build's installation id, or its package id; say so to the user
        rather than retrying blindly.
        """,
    )
}
