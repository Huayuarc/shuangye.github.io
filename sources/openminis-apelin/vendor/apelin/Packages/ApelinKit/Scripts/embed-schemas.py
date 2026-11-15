#!/usr/bin/env python3
"""Writes Documents/Schemas/*.schema.json into ApelinProject as Swift raw strings.

The schemas are the specification; apelin-build validates against them on the
device, where the repository is not. ApelinProjectTests fails when the
embedded copy and the files differ, so run this after editing a schema.
"""
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[3]
TARGET = REPOSITORY / "Packages/ApelinKit/Sources/ApelinProject/JSON/EmbeddedSchemas.swift"

lines = [
    "// Generated from Documents/Schemas/*.schema.json; do not edit.",
    "// ApelinProjectTests fails when this file and the schemas differ. Regenerate with:",
    "//   Packages/ApelinKit/Scripts/embed-schemas.py",
    "",
    "enum EmbeddedSchemas {",
]
for name, ident in (("apelin-project.schema.json", "project"), ("extension-manifest.schema.json", "manifest")):
    text = (REPOSITORY / "Documents/Schemas" / name).read_text(encoding="utf-8")
    if '"""#' in text or "\\#" in text:
        raise SystemExit(f"{name} cannot be embedded as a raw string")
    lines += [f'    static let {ident} = #"""', text.rstrip("\n"), '"""#', ""]
lines[-1] = "}"
TARGET.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"wrote {TARGET.relative_to(REPOSITORY)}")
