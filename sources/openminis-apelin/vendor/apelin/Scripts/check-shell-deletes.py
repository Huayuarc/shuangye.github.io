#!/usr/bin/env python3
"""Fail when a recursive `rm` names a shell variable it has not checked.

An empty variable in a removed path takes the path with it: the folder
becomes `/`, and on roothide `/` is the bootstrap's root, where a build
script runs as mobile and a maintainer script as root. `${name:?}` makes the
shell stop with an error before the command runs, so every variable in a
recursive `rm` is spelled that way, in Apelin's own scripts, in the files it
writes into a user's repository (DistributionTemplate) and in the script the
agent's skills hand out.

Each line is read on its own. In a command that starts with `rm` and has a
recursive option (`-r`, `-R`, `-rf`, `--recursive`, …), up to the next `;`,
`&&`, `||`, `|` or backquote, a parameter expansion — `$name`, `${name}`,
Make's `$$name`, a Python f-string's `${{name}}` — passes only as
`${name:?…}`. An escaped `\\$` is another shell's and is not read. Swift test
sources and schema fixtures hold commands as data and are not read.

Usage: check-shell-deletes.py <root>

Exit 0 clean, 65 when an unchecked variable is found.
"""

import os
import re
import sys

SKIP_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "node_modules", ".claude", "Licenses"}
SKIP_PATHS = ("Packages/Runestone/", "Documents/Schemas/Fixtures/")
SELF = os.path.basename(__file__)

# `rm` as a command word, then its options.
REMOVE = re.compile(r"""(?:^|[\s;&|('"`{])rm((?:\s+-[A-Za-z-]+)+)""")
RECURSIVE = re.compile(r"^-(?:[A-Za-z]*[rR][A-Za-z]*|-recursive)$")
END = re.compile(r";|&&|\|\||\||`|$")
# A parameter expansion: optional Make `$`, optional brace (doubled in an
# f-string), then the name.
EXPANSION = re.compile(r"(?<!\\)\$\$?(\{\{?)?([A-Za-z_][A-Za-z0-9_]*|[0-9])")


def read(path):
    name = os.path.basename(path)
    if name == SELF:
        return False
    if name == "Makefile" or name.endswith((".sh", ".py")):
        return True
    if os.path.basename(os.path.dirname(path)) == "DEBIAN":
        return True
    if name.endswith(".swift"):
        return "/Tests/" not in path
    return name.endswith(".json") and "/Console/" in path


def unchecked(line):
    names = []
    for command in REMOVE.finditer(line):
        if not any(RECURSIVE.match(option) for option in command.group(1).split()):
            continue
        rest = line[command.end():]
        segment = rest[: END.search(rest).start()]
        for expansion in EXPANSION.finditer(segment):
            braced = expansion.group(1) is not None
            if not (braced and segment[expansion.end():].startswith(":?")):
                names.append(expansion.group(2))
    return names


def main(root):
    problems = []
    for directory, folders, files in os.walk(root):
        folders[:] = sorted(folder for folder in folders if folder not in SKIP_DIRS)
        for name in sorted(files):
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            if relative.startswith(SKIP_PATHS) or not read(path):
                continue
            try:
                with open(path, encoding="utf-8") as handle:
                    lines = handle.readlines()
            except (OSError, UnicodeDecodeError):
                continue
            for number, line in enumerate(lines, 1):
                for variable in unchecked(line):
                    problems.append(f"{relative}:{number}: a recursive rm uses ${variable} unchecked; spell it ${{{variable}:?}}")
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print("error: an empty variable would remove from / (the bootstrap's root on roothide)", file=sys.stderr)
        return 65
    print("ok: every recursive rm checks its variables")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
