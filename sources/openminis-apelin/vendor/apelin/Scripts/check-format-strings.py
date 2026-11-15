#!/usr/bin/env python3
"""Fail the build when a translation's format arguments do not match its key.

A key such as `Session %lld on %@` is a format string, and every translation
of it is handed the same arguments in the same order. A translation that puts
them in another order has to say so with positions (`%2$@ … %1$lld`); one
that simply writes `%@ … %lld` reads the number as an object pointer, and
`String.localizedStringWithFormat` crashes on the first screen that shows it —
in that language only, so nothing in an English build ever notices. That is
how it shipped once.

For every key with format specifiers this compares, per argument position,
the kind each translation consumes (an object for `%@`, a number for the
integer and float conversions) with the kind the key passes. A translation
may leave an argument out (a plural form that spells the number in words);
it may not read one the key does not pass, or read it as the other kind.

Usage: check-format-strings.py <root> [<root> ...]

Exit 0 clean, 65 when a mismatch is found, 66 when a catalog will not parse.
"""

import json
import os
import re
import sys

SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+ 0#']*\d*(?:\.\d+)?(lld|llu|ld|lu|hhd|hd|d|i|u|x|X|@|f|g|e|s|c)")


def arguments(text):
    """{position: kind} for the specifiers in `text`; None when two of them
    claim one position as different kinds."""
    found = {}
    implicit = 0
    for match in SPECIFIER.finditer(text.replace("%%", "")):
        if match.group(1):
            position = int(match.group(1))
        else:
            implicit += 1
            position = implicit
        conversion = match.group(2)
        kind = "object" if conversion == "@" else "cstring" if conversion in ("s", "c") else "number"
        if found.setdefault(position, kind) != kind:
            return None
    return found


def values(localization):
    unit = localization.get("stringUnit")
    if unit:
        yield unit.get("value", "")
    for variation in localization.get("variations", {}).values():
        for case in variation.values():
            yield from values(case)


def check(path):
    try:
        with open(path, encoding="utf-8") as handle:
            strings = json.load(handle).get("strings", {})
    except (OSError, ValueError) as error:
        print(f"error: {path}: {error}", file=sys.stderr)
        return None
    problems = []
    for key, entry in strings.items():
        expected = arguments(key)
        if not expected:
            continue
        for language, localization in entry.get("localizations", {}).items():
            for value in values(localization):
                actual = arguments(value)
                if actual is None or any(expected.get(position) != kind for position, kind in actual.items()):
                    problems.append(f"{path}: {language}: {key!r} -> {value!r}")
    return problems


def main(roots):
    catalogs = []
    for root in roots:
        for directory, _, files in os.walk(root):
            catalogs += [os.path.join(directory, name) for name in files if name.endswith(".xcstrings")]
    failed = False
    for path in sorted(catalogs):
        problems = check(path)
        if problems is None:
            return 66
        for problem in problems:
            print(f"error: format arguments do not match the key: {problem}", file=sys.stderr)
            failed = True
    if failed:
        print("error: a reordered argument needs a position, as in %2$@ … %1$lld", file=sys.stderr)
        return 65
    print(f"ok: format arguments match their keys in {len(catalogs)} string catalog(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["."]))
