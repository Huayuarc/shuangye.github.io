#!/usr/bin/env python3
"""Fail when a shipped Mach-O needs an @rpath library nothing provides.

Run by Scripts/package-deb.sh on the staged package root. For every Mach-O
in it (the app, its embedded libraries, apelind, the workers, anything
installed beside them), every strong `@rpath/<name>` dependency has to resolve:

- through an `@executable_path`, `@loader_path` or absolute rpath to a file
  in the package, or
- through an absolute system rpath to a library the OS ships at that path on
  every iOS from the floor up (FLOOR_LIBRARIES below).

dyld tries the rpaths in order and kills the process before `main` when none
holds the file, and only on the device that lacks it: apelin-agent once
linked `@rpath/libswiftCompatibilitySpan.dylib` with `/usr/lib/swift` as its
only rpath, which iOS 26 satisfies and iOS 16–18 do not. A weak dependency
is allowed to be missing. `@executable_path/…` and `@loader_path/…`
dependencies are checked the same way.

Usage: check-rpath-dependencies.py <package root> <install prefix>
"""

import os
import subprocess
import sys

# Libraries the OS provides at <rpath>/<name> on every iOS from
# IPHONEOS_DEPLOYMENT_TARGET up, for an @rpath dependency to count as
# satisfied without a copy in the package. A back-deployed Swift runtime
# library (libswiftCompatibilitySpan.dylib is in the OS from iOS 26) is never
# here: it ships in the package, after the OS's copy in the rpath order.
FLOOR_LIBRARIES = {
    # "/usr/lib/swift": {"libswiftExample.dylib"},
}

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
}
LOAD_COMMANDS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB"}


def is_macho(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in MACHO_MAGICS
    except OSError:
        return False


def load_commands(path):
    """(dependencies as (name, weak), rpaths) from `otool -l`."""
    output = subprocess.run(["otool", "-l", path], check=True, capture_output=True, text=True).stdout
    dependencies, rpaths, command = [], [], None
    for line in output.splitlines():
        words = line.split()
        if len(words) >= 2 and words[0] == "cmd":
            command = words[1]
        elif len(words) >= 2 and words[0] == "name" and command in LOAD_COMMANDS:
            dependencies.append((words[1], command == "LC_LOAD_WEAK_DYLIB"))
        elif len(words) >= 2 and words[0] == "path" and command == "LC_RPATH":
            rpaths.append(words[1])
    # A universal file lists each slice's commands in turn; duplicates are harmless.
    return dependencies, rpaths


def executable_directory(path, root):
    """The directory @executable_path names for this image: the innermost
    bundle with a main executable that holds it — an .appex inside an .app
    is its own process — else the image's own directory."""
    relative = os.path.relpath(path, root)
    parts = relative.split(os.sep)
    for index in range(len(parts) - 1, -1, -1):
        if parts[index].endswith((".app", ".appex")):
            return os.path.join(root, *parts[: index + 1])
    return os.path.dirname(path)


def resolve(template, image, root, prefix):
    """The staged file a path template names, or None for a system path."""
    if template.startswith("@executable_path"):
        return os.path.normpath(executable_directory(image, root) + template[len("@executable_path"):])
    if template.startswith("@loader_path"):
        return os.path.normpath(os.path.dirname(image) + template[len("@loader_path"):])
    if template.startswith("/"):
        staged = os.path.normpath(root + template)
        inside = os.path.normpath(root + (prefix or "/"))
        if staged == inside or staged.startswith(inside + os.sep):
            return staged
    return None


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    root, prefix = os.path.realpath(sys.argv[1]), sys.argv[2]
    failures, checked = [], 0
    for directory, _, files in os.walk(root):
        for filename in sorted(files):
            image = os.path.join(directory, filename)
            if os.path.islink(image) or not is_macho(image):
                continue
            checked += 1
            dependencies, rpaths = load_commands(image)
            shown = os.path.relpath(image, root)
            for name, weak in dependencies:
                if weak:
                    continue
                if name.startswith("@rpath/"):
                    leaf = name[len("@rpath/"):]
                    satisfied = False
                    for rpath in rpaths:
                        staged = resolve(rpath, image, root, prefix)
                        if staged is not None:
                            if os.path.isfile(os.path.join(staged, leaf)):
                                satisfied = True
                                break
                        elif leaf in FLOOR_LIBRARIES.get(rpath.rstrip("/"), set()):
                            satisfied = True
                            break
                    if not satisfied:
                        failures.append(f"{shown}: {name} resolves through none of its rpaths {rpaths or '(none)'} "
                                        "to a file in the package or a library the OS has on the floor")
                elif name.startswith("@executable_path") or name.startswith("@loader_path"):
                    staged = resolve(name, image, root, prefix)
                    if staged is None or not os.path.isfile(staged):
                        failures.append(f"{shown}: {name} is not in the package")
    if checked == 0:
        sys.exit("error: check-rpath-dependencies: no Mach-O under " + root)
    for failure in failures:
        print("error: " + failure, file=sys.stderr)
    if failures:
        sys.exit(65)
    print(f"check-rpath-dependencies: {checked} Mach-O files, every @rpath dependency resolves")


if __name__ == "__main__":
    main()
