extension BuiltInSkills {
    static let bootstrapPaths = SkillDocument(
        name: "apelin-bootstrap-paths",
        description: "How roothide and rootless spell paths, so a tweak, a script or a plist names a file the way the thing that opens it expects: jbroot vs /var/jb, /rootfs, @PREFIX@ and @ROOTFS@, @loader_path/.jbroot, which paths never change, and why a resolved jbroot path is never written down. Read before writing any path in code, a build script, a maintainer script or a note.",
        body: """
        # Bootstrap paths

        A jailbreak installs its files under a root that is not `/`. Code,
        scripts and plists on the device run in different worlds, and a path
        spelled for the wrong one points nowhere. Get this right before you
        write a path.

        The build tells C and Objective-C code which bootstrap it is building
        for: `APELIN_BOOTSTRAP_ROOTHIDE` or `APELIN_BOOTSTRAP_ROOTLESS` is `1`
        (Swift gets them as conditions). The environment section of the system
        prompt names this device's bootstrap and its install root.

        ## The two bootstraps
        - **rootless**: everything is under the fixed `/var/jb`. A package's
          dylib lives at `/var/jb/Library/MobileSubstrate/DynamicLibraries/`,
          a tool at `/var/jb/usr/bin/`. The architecture is `iphoneos-arm64`.
        - **roothide**: everything is under a folder named `.jbroot-` and
          sixteen hex digits, below `/var/containers/Bundle/Application`,
          whose name is random and **changes at every jailbreak**. There is no
          `/var/jb`. The architecture is `iphoneos-arm64e`. roothide puts a
          `.jbroot` symbolic link in each folder that holds a Mach-O, pointing
          at the current jbroot, so a binary reaches bootstrap libraries
          through `@loader_path/.jbroot/…` (the tweak extension's link stubs
          set this; you write no install names).
        Because the roothide root moves, never write it down, cache it across
        launches, or hard-code `/var/jb` for it (below: never store a
        resolved path).

        ## Three worlds, three spellings
        1. **Your compiled code** (the tweak, a tool) is Apple's ABI and is
           not vroot-linked, so it opens files at their real kernel path. A
           bootstrap path like `/Library/…` must be made absolute first:
           `/var/jb` + path on rootless, the jbroot + path on roothide. This
           skill's file `ApelinBootstrap.h` does exactly that (apelin_skill_read with
           that file); it is what roothide's `jbroot()` and rootless's
           `ROOT_PATH_NS()` do, written so the one source builds for both
           bootstraps. System paths — `/System`, `/usr/lib/libSystem.B.dylib`,
           `/var/mobile/Library/Preferences`, a container — are already real
           and are **not** converted; converting one breaks it.
        2. **The bootstrap's shell and its tools** (what shell_run's `bash`,
           the terminal and a build script use on roothide) are vroot-linked:
           the jbroot is their `/`, and the real filesystem is under
           `/rootfs`. So `pwd -P`, `realpath` and `readlink` in that shell
           print `/var/mobile/…` for a path your compiler knows by the jbroot,
           and a path the shell prints is not the name to hand a compiler.
           Give the compiler relative paths or `$APELIN_PROJECT_ROOT`. On
           rootless the shell and the kernel agree (`/var/jb`).
        3. **launchd and the installer** read a plist or run a script in the
           bootstrap. See the two sections below.

        ## In a plist (launch daemon, filter)
        The packager fills two tokens, so one file serves both bootstraps:
        - `@PREFIX@` — a bootstrap path's prefix: empty on roothide, `/var/jb`
          on rootless. A daemon's `Program`, `WorkingDirectory`,
          `Standard*Path`, `WatchPaths`, `QueueDirectories` and sockets under
          the bootstrap are `@PREFIX@/…`.
        - `@ROOTFS@` — a system path's prefix for a key launchd rewrites:
          `/rootfs` on roothide, empty on rootless. A system directory the
          daemon watches or logs to is `@ROOTFS@/…`.
        roothide's launchctl puts the jbroot in front of each of these keys
        unless the path starts with `/rootfs/`, so a **system** path spelled
        bare is watched, logged to or entered inside the jbroot, where it does
        not exist: nothing fails and the job is never started (Xrash's
        `WatchPaths`). A bootstrap path without `@PREFIX@` misses `/var/jb`
        on rootless. Set `substitutePrefix: true` on the layout entry so the
        packager fills the tokens. Never write a resolved jbroot or a bare
        `/var/jb` into a plist.

        ## In a maintainer script
        The installer runs it with the bootstrap's own shell: on roothide the
        jbroot is its `/` (so `/var/mobile` there is the jbroot's) and the
        system is under `/rootfs`; on rootless paths are `/var/jb/…`. The packager substitutes only `@PREFIX@` and `@ROOTFS@`
        (and requires `sh -n` to pass), so write bootstrap paths `@PREFIX@/…`
        and the few system paths you need `@ROOTFS@/…`. A link you create in a
        script, or ship in the package, must be **relative**: an absolute
        target resolves against the system on roothide. The packaging-and-
        install skill has the rest (making mobile's folders, restarting a
        daemon).

        ## Never store a resolved path
        On roothide everything under the jbroot moves when it is renamed:
        Apelin's data folder (in the jbroot's own `var/mobile`), the
        project's real path, `$APELIN_PROJECT_ROOT`, `$APELIN_TOOLCHAIN_BIN`,
        `SDKROOT`, every toolchain's and SDK's folder. A path read today (in
        a tool's result, the environment section or a variable's value) may
        be gone after the next reboot or jailbreak, so the jbroot's real
        path, or any path under it, never goes into anything that outlives
        the run: project files, build scripts, Makefiles, `AGENTS.md` or
        `CLAUDE.md`, memory, skills, plists, package or maintainer scripts,
        code. Keep the logical spelling and resolve it where it is used:
        - code: `ApelinBootstrapPath(@"/Library/…")` at run time, as
          roothide's `jbroot("/Library/…")` does; never its result as a
          literal.
        - a plist or maintainer script: `@PREFIX@/…`, `@ROOTFS@/…`.
        - a build script or Makefile: the variables Apelin sets when it runs
          (`$APELIN_PROJECT_ROOT`, `$SDKROOT`, `$APELIN_TOOLCHAIN_BIN`, and
          for a workspace build `$APELIN_PREFIX` and `$APELIN_PACKAGE_DIR`),
          or paths relative to the project. Each is checked before it is
          used (`${APELIN_PACKAGE_DIR:?}`), since a run that did not set it
          leaves it empty; `$APELIN_PREFIX` is empty on roothide by design,
          so nothing is removed under it alone.
        - a note (`AGENTS.md`, memory, a skill): the place in words or a
          variable ("the project root", "the registered iOS 17 SDK",
          `$SDKROOT`), never its path.
        On rootless `/var/jb` and `/var/mobile` do not move, so nothing there
        goes stale on this device; still spell paths as above, since the
        project also builds for roothide, and write a bare `/var/jb` only
        where the code is rootless's alone (`APELIN_BOOTSTRAP_ROOTLESS`).

        ## Quick rules
        - Opening a bootstrap file from your own code → make it absolute with
          `ApelinBootstrap.h`'s `ApelinBootstrapPath`.
        - A system file (`/var/mobile/…`, `/System/…`, a container) from your
          code → use it as it is.
        - A path for a compiler, from a script → relative or
          `$APELIN_PROJECT_ROOT`, never one a bootstrap tool printed.
        - A path in a plist or maintainer script → `@PREFIX@/…` or
          `@ROOTFS@/…`, `substitutePrefix: true` for a shipped file.
        - Comparing two paths → canonicalise both first (`realpath`): `/var`
          and `/private/var` differ, and the jbroot may itself be a link.
        - Writing a path into a file, a note or memory → its logical spelling
          or a variable, never the jbroot's real path.
        """,
        files: ["ApelinBootstrap.h": bootstrapHeader],
    )

    /// A C/Objective-C helper the tweak and apelin-bootstrap-paths skills point at.
    /// Compiled by hand for roothide arm64e and rootless arm64 with the
    /// template's flags (clang -fobjc-arc -Werror=unguarded-availability-new
    /// -fvisibility=hidden) before shipping; a test holds that the skill still
    /// carries it. Keep it warning-clean for both bootstraps if you edit it.
    static let bootstrapHeader = """
    // SPDX-License-Identifier: MIT
    //
    // ApelinBootstrap.h — spell a bootstrap path the way your own compiled
    // code must open it, on both roothide and rootless, from one source.
    //
    // Your tweak or tool runs with Apple's ABI (not vroot), so it opens files
    // at their real kernel path. A bootstrap path such as
    //   /Library/MobileSubstrate/DynamicLibraries/X.dylib
    // is NOT that: on rootless it is under /var/jb, on roothide under the
    // randomly named jbroot this image was loaded from. ApelinBootstrapPath()
    // makes it absolute. A SYSTEM path — /System, /usr/lib/libSystem.B.dylib,
    // /var/mobile/Library/Preferences, an app container — is already real:
    // pass it as it is, never through ApelinBootstrapPath().
    //
    // This is what roothide's jbroot() and rootless's ROOT_PATH_NS() do; it is
    // here so the one source builds for both without libroothide or libroot.
    // The build defines APELIN_BOOTSTRAP_ROOTHIDE or APELIN_BOOTSTRAP_ROOTLESS.
    #pragma once

    #import <Foundation/Foundation.h>
    #import <dlfcn.h>

    // The bootstrap's root as the kernel spells it, or nil if it cannot be
    // found (roothide, no .jbroot- ancestor). Cached for the process; do not
    // persist it — roothide renames the jbroot at every jailbreak.
    static inline NSString *_Nullable ApelinBootstrapRoot(void) {
    #ifdef APELIN_BOOTSTRAP_ROOTHIDE
        static NSString *root;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            static const char anchor = 0;
            Dl_info info;
            if (dladdr(&anchor, &info) == 0 || info.dli_fname == NULL) {
                return;
            }
            NSArray<NSString *> *parts =
                [@(info.dli_fname) componentsSeparatedByString:@"/"];
            for (NSUInteger i = 0; i < parts.count; i++) {
                if ([parts[i] hasPrefix:@".jbroot-"]) {
                    root = [[parts subarrayWithRange:NSMakeRange(0, i + 1)]
                        componentsJoinedByString:@"/"];
                    break;
                }
            }
        });
        return root;
    #else
        return @"/var/jb";
    #endif
    }

    // A bootstrap path (/Library/..., /usr/bin/x) as your code must open it.
    // Nil only when the roothide root cannot be found; handle it.
    static inline NSString *_Nullable ApelinBootstrapPath(NSString *_Nonnull path) {
        NSString *root = ApelinBootstrapRoot();
        return root == nil ? nil : [root stringByAppendingString:path];
    }
    """
}
