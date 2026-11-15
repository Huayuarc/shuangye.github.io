#!/usr/bin/env python3
"""Fail the build when a string the compiler extracted is not in its catalog.

`check-translations.py` reads the catalog, so it only sees keys that reached
it. A key reaches it when Xcode merges the compiler's `.stringsdata` back into
the `.xcstrings` file, which the IDE does and `xcodebuild` does not. A string
added by an agent or on the command line therefore never lands in the catalog
at all, every gate passes, and every language shows it in English: the Model
Providers `…` menu read "Edit" between 模型 and 退出登录 that way. So did a key
whose literal was spelled with ' while its catalog entry has ’.

This reads the `.stringsdata` the build just wrote for a target and refuses
any key of its `Localizable` table the target's catalog lacks. A file whose
source no longer exists is an incremental build's leftover and is skipped.

Usage: check-catalog-keys.py <catalog> <target build folder> [<catalog> <folder> ...]

Exit 0 clean, 64 on a bad command line, 65 when a key is missing, 66 when a
file will not parse or a folder holds no `.stringsdata` (the build stopped
emitting them).
"""

import json
import os
import sys

USAGE = "usage: check-catalog-keys.py <catalog> <target build folder> [<catalog> <folder> ...]"


def extracted(folder):
    """{key: [source:line, …]} from every current `.stringsdata` under folder."""
    keys = {}
    found = False
    for directory, _, files in os.walk(folder):
        for name in files:
            if not name.endswith(".stringsdata"):
                continue
            found = True
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                data = json.load(handle)
            source = data.get("source", "")
            if not os.path.isfile(source):
                continue
            for entry in data.get("tables", {}).get("Localizable", []):
                if entry["key"]:
                    line = entry.get("location", {}).get("startingLine", 0)
                    keys.setdefault(entry["key"], []).append(f"{source}:{line}")
    if not found:
        raise ValueError(f"{folder}: no .stringsdata (is SWIFT_EMIT_LOC_STRINGS on?)")
    return keys


def main(arguments):
    if not arguments or len(arguments) % 2:
        print(USAGE, file=sys.stderr)
        return 64
    problems = []
    try:
        for catalog, folder in zip(arguments[::2], arguments[1::2]):
            with open(catalog, encoding="utf-8") as handle:
                strings = json.load(handle).get("strings", {})
            for key, places in sorted(extracted(folder).items()):
                if key not in strings:
                    problems.append(f"{sorted(set(places))[0]}: {key!r} is not in {catalog}")
    except (OSError, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 66
    for problem in problems:
        print(f"error: not in the catalog: {problem}", file=sys.stderr)
    if problems:
        print("error: add each key to its catalog with every language (check-translations.py)", file=sys.stderr)
        return 65
    print(f"ok: every extracted string is in its catalog ({len(arguments) // 2} target(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
