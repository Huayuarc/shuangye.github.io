#!/usr/bin/env python3
"""Fail the build when a string is missing a shipped language.

Apelin ships the languages its sibling apps ship (owner, 2026-10-22):
English and the twelve below. A key added in English only renders the
English text on a Japanese or Arabic device and never warns, so every key
a catalog asks to translate needs a translated unit, or plural variations,
in each of them. Keys marked `shouldTranslate: false` are skipped.

The InfoPlist.strings beside the app's resources (`<language>.lproj`) are
checked too: each language's file names the same keys as English's.

Usage: check-translations.py <root> [<root> ...]

Exit 0 clean, 65 when something is missing, 66 when a file will not parse.
"""

import json
import os
import subprocess
import sys

LANGUAGES = ["ar", "de", "es", "fr", "it", "ja", "ko", "pt-BR", "ru", "vi", "zh-Hans", "zh-Hant"]


def translated(localization):
    unit = localization.get("stringUnit")
    if unit:
        return unit.get("state") == "translated" and bool(unit.get("value"))
    variations = localization.get("variations", {})
    return bool(variations) and all(
        translated(case) for variation in variations.values() for case in variation.values()
    )


def check_catalog(path):
    with open(path, encoding="utf-8") as handle:
        strings = json.load(handle).get("strings", {})
    problems = []
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        missing = [language for language in LANGUAGES if not translated(localizations.get(language, {}))]
        if missing:
            problems.append(f"{path}: {key!r} has no {', '.join(missing)}")
    return problems


def strings_keys(path):
    """The keys of a .strings file, read by plutil (old-style plists)."""
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, check=False)
    if result.returncode != 0:
        raise ValueError(f"{path}: {result.stderr.decode(errors='replace').strip()}")
    return set(json.loads(result.stdout))


def check_info_plist_strings(directory):
    english = os.path.join(directory, "en.lproj", "InfoPlist.strings")
    if not os.path.isfile(english):
        return []
    keys = strings_keys(english)
    problems = []
    for language in LANGUAGES:
        path = os.path.join(directory, f"{language}.lproj", "InfoPlist.strings")
        if not os.path.isfile(path):
            problems.append(f"{path}: missing")
            continue
        missing = keys - strings_keys(path)
        if missing:
            problems.append(f"{path}: has no {', '.join(sorted(missing))}")
    return problems


def main(roots):
    catalogs = []
    resource_folders = set()
    for root in roots:
        for directory, _, files in os.walk(root):
            catalogs += [os.path.join(directory, name) for name in files if name.endswith(".xcstrings")]
            if os.path.basename(directory) == "en.lproj" and "InfoPlist.strings" in files:
                resource_folders.add(os.path.dirname(directory))
    problems = []
    try:
        for path in sorted(catalogs):
            problems += check_catalog(path)
        for folder in sorted(resource_folders):
            problems += check_info_plist_strings(folder)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 66
    for problem in problems:
        print(f"error: untranslated: {problem}", file=sys.stderr)
    if problems:
        print(f"error: every string needs {', '.join(LANGUAGES)} besides English", file=sys.stderr)
        return 65
    print(f"ok: {len(LANGUAGES)} languages in {len(catalogs)} string catalog(s) and InfoPlist.strings")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["."]))
