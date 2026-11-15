extension BuiltInSkills {
    static let tweakRuntime = SkillDocument(
        name: "apelin-tweak-runtime",
        description: "How a tweak behaves at run time inside another process: logging with os_log so apelin_log_read can see it, what the host's sandbox lets it read and write, reading settings, and telling another process something changed with a Darwin notification. Read when a tweak logs, stores a setting, reads files, or talks to another process.",
        body: """
        # A tweak at run time

        Your dylib runs inside the host process (an app, SpringBoard, a
        daemon), under that process's user, sandbox and entitlements. You
        cannot grant yourself more; design within what the host already has.
        Paths in anything below are spelled as the apelin-bootstrap-paths skill says.

        ## Logging — the only record you can read back
        - Log with `os_log` to a logger whose subsystem is the package ID, as
          the template's `TweakLog()` does
          (`os_log_create(APELIN_PACKAGE_ID, "<category>")`). This is how
          apelin_log_read and apelin_package_confirm_loaded find your lines.
        - The unified log has no history on iOS: it is read live, so a line is
          seen only while something listens. apelin_log_read listens from the
          moment it is called for at most 10 seconds (`listen_seconds` sets
          how long; nothing is read back), and your tool calls run one at a
          time, so it hears only what the host logs during the call on its
          own: something that recurs, or something the user does while it
          runs — tell them first. A line logged once at the host's launch is
          apelin_package_confirm_loaded's (with `respring: true` for SpringBoard). To trace
          a hook, log on each call, with the build ID, rate-limited if it is
          hot. Filter by `subsystem` (your package ID; dotted children
          included).
        - A value in a log line is private by default: integers, floats and
          bools print, but a string or object is redacted unless you mark it
          `%{public}`. Mark what you need to read, and never log a secret.
          Keep the `ApelinLoaded` marker public.
        - Levels are `debug`, `info`, `default`, `error`, `fault`; `default`
          and `notice` are one level to the reader. The system keeps `debug`
          and `info` only in memory, so log what you must read back with
          `os_log` (default) or `os_log_error`. A busy device drops lines the
          stream cannot hold.
        - Do not write a log file of your own inside the host: the host's
          sandbox usually forbids it, and a file in a place a sandboxed
          process cannot reach is lost. The unified log is the record; if a
          file is truly needed, it belongs to a daemon your package ships,
          not to the injected dylib.

        ## The sandbox you inherit
        - A tweak in a **sandboxed app** is confined to that app: it reads the
          app's own container and world-readable system files, and little
          else. Reading another app's container, the keychain or a data vault
          (`/var/mobile/Library/Photos`, `/var/mobile/Library/Preferences`
          from inside a sandbox, …) needs an entitlement the host does not
          have, so it fails with EPERM — root does not lift a data vault, and
          you are not root inside an app anyway.
        - Files a jailbroken process can read live under the bootstrap root.
          Of those, a tweak can reliably **write** only under the bootstrap's
          `/var` (apelin-bootstrap-paths). Do not try to write elsewhere from the
          injected code; if the task needs a privileged or shared write, a
          daemon your package ships does it.
        - Probe access by trying the operation (open the file, `opendir` the
          folder) and handling the error, not with `access()`: a sandboxed
          process can often `stat` a directory it cannot list.

        ## Reading a setting
        Two ways, both fine; pick one and be consistent.
        - **A plist you own**, read directly: a dictionary at
          `<bootstrap>/var/mobile/Library/Preferences/<package id>.plist`
          (make the path with apelin-bootstrap-paths). This avoids cfprefsd, which a
          sandboxed app calling it in a constructor has been seen to deadlock
          with, and whose cross-domain reads some jailbreaks refuse from a
          sandbox. The apelin-preference-bundle skill's Settings pane writes this
          file and posts a notification.
        - **CFPreferences** in your own domain
          (`CFPreferencesCopyAppValue(key, CFSTR(APELIN_PACKAGE_ID))`), read
          after the host is up, not in the constructor. cfprefsd flushes to
          disk a few seconds after a write, so a direct file read right after
          a CFPreferences write can see the old bytes.
        Fall back to a coded default for a missing key. Many hosts read a
        setting only at launch, so a change often takes effect on the host's
        next launch (a respring for SpringBoard).

        ## Telling another process something changed
        - A Darwin notification is the lightweight signal between processes:
          `notify_register_dispatch(name, &token, queue, handler)` to listen,
          `notify_post(name)` to fire. Name it under your package id, such as
          `<package id>/changed`, as the preference pane does.
        - It carries **no payload**: object, userInfo and "deliver
          immediately" are all ignored. It says only "this happened"; the
          receiver then re-reads the setting or file. Delivery needs the
          main run loop running in a common mode.
        - It is system-wide and has no sessions; post only names whose
          listeners you understand, and never a `com.apple.*` name. notifyd
          keeps a name's state only while something is registered for it.
        - For a value, not a signal, write the plist (or a file) and post the
          notification; the reader reads the file. A file two processes share
          is replaced atomically (write a temporary beside it, `rename`),
          which changes the inode, so a watcher watches the **directory**, not
          the file.
        """,
    )
}
