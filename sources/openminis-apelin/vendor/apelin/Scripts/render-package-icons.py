#!/usr/bin/env python3
"""Draw the package icons that every Apelin deb names in its `Icon:` field.

Each extension's icon is Apelin's own — the light plate and the braces from
Documents/Icon/AppIcon.icon — with the leaf swapped for a green mark of what
the package adds. The marks are written here; the script writes one SVG per
package to Documents/Icon/Packages/ and renders it with Chrome to a 512 px
PNG in Documents/Site/icons/, which Pages serves at
https://owngoal-dev.github.io/Apelin/icons/<name>.png. Apelin's own icon stays
Documents/Site/icon.png, rendered from the .icon.

The four development extensions' icons are also each project kind's icon in
the app: the plate alone on a clear ground, written as 1x–3x PNGs into the
`ProjectIcon<Kind>` image sets.

Run it again after changing a mark: Scripts/render-package-icons.py
"""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Documents/Icon/Packages"
OUTPUT = ROOT / "Documents/Site/icons"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SIZE = 512
ASSETS = ROOT / "Apelin/Resources/Assets.xcassets"
# The image sets are drawn at 40 points, the most the app shows one at.
ASSET_POINTS = 40

# Each project kind's image set, and the extension whose mark it takes.
PROJECT_ICONS = {
    "ProjectIconApp": ("wiki.qaq.apelin.dev.app", "app"),
    "ProjectIconTweak": ("wiki.qaq.apelin.dev.tweak", "tweak"),
    "ProjectIconTool": ("wiki.qaq.apelin.dev.cli", "tool"),
    "ProjectIconPreferences": ("wiki.qaq.apelin.dev.preferences", "preferences"),
}

# The braces, as in Documents/Icon/AppIcon.icon/Assets/braces-light.svg.
BRACES = """
 <g fill="none" stroke="#1F242E" stroke-width="56" stroke-linecap="round" stroke-linejoin="round" filter="url(#lift)">
  <path d="M 326 300 C 272 300 262 330 262 380 L 262 456 C 262 494 248 512 210 512 C 248 512 262 530 262 568 L 262 644 C 262 694 272 724 326 724"/>
  <path d="M 698 300 C 752 300 762 330 762 380 L 762 456 C 762 494 776 512 814 512 C 776 512 762 530 762 568 L 762 644 C 762 694 752 724 698 724"/>
 </g>"""

# Marks sit inside the braces, roughly 372…652 on both axes. `fill` and
# `stroke` of "url(#green)" take the leaf's colour with its light from above.
MARKS = {
    # A home screen's worth of apps.
    "wiki.qaq.apelin.dev.app": """
  <g fill="url(#green)">
   <rect x="376" y="376" width="122" height="122" rx="34"/>
   <rect x="526" y="376" width="122" height="122" rx="34"/>
   <rect x="376" y="526" width="122" height="122" rx="34"/>
   <rect x="526" y="526" width="122" height="122" rx="34"/>
  </g>""",
    # A hook: what a tweak does to a method.
    "wiki.qaq.apelin.dev.tweak": """
  <g fill="none" stroke="url(#green)" stroke-width="44" stroke-linecap="round" stroke-linejoin="round">
   <circle cx="560" cy="398" r="28"/>
   <path d="M 560 426 L 560 566 C 560 626 524 656 480 656 C 436 656 408 626 408 584 L 408 556 L 454 596"/>
  </g>""",
    # A shell prompt.
    "wiki.qaq.apelin.dev.cli": """
  <g fill="none" stroke="url(#green)" stroke-width="48" stroke-linecap="round" stroke-linejoin="round">
   <path d="M 392 418 L 482 512 L 392 606"/>
   <path d="M 528 606 L 636 606"/>
  </g>""",
    # A switch, turned on, as in Settings.
    "wiki.qaq.apelin.dev.preferences": """
  <rect x="364" y="438" width="296" height="148" rx="74" fill="url(#green)"/>
  <circle cx="586" cy="512" r="58" fill="#FFFFFF" filter="url(#lift)"/>""",
    # Assembly in, machine code out: a 1 and a 0.
    "wiki.qaq.apelin.agent-tools.assembler": """
  <g fill="none" stroke="url(#green)" stroke-width="44" stroke-linecap="round" stroke-linejoin="round">
   <path d="M 396 420 L 438 392 L 438 632"/>
   <rect x="514" y="392" width="122" height="240" rx="61"/>
  </g>""",
    # Machine code read back as a listing.
    "wiki.qaq.apelin.agent-tools.disassembler": """
  <g fill="none" stroke="url(#green)" stroke-width="44" stroke-linecap="round">
   <path d="M 390 414 L 634 414"/>
   <path d="M 438 488 L 594 488"/>
   <path d="M 438 562 L 634 562"/>
   <path d="M 390 636 L 540 636"/>
  </g>""",
    # A hammer: the compilers set up on the device.
    "wiki.qaq.apelin.toolchain": """
  <g transform="rotate(-45 512 512)">
   <path d="M 512 470 L 512 660" fill="none" stroke="url(#green)" stroke-width="48" stroke-linecap="round"/>
   <path d="M 420 400 C 420 384 432 372 448 372 L 592 372 C 616 372 640 388 652 410 L 662 430 C 666 438 660 448 650 448 L 448 448 C 432 448 420 436 420 420 Z" fill="url(#green)"/>
  </g>""",
}


def svg(mark: str, clear: bool = False) -> str:
    """The icon on a white square, as a package manager shows it, or with
    `clear` the plate alone, edge to edge, on a transparent ground."""
    if clear:
        ground = ""
        plate = '<rect x="1" y="1" width="1022" height="1022" rx="229" fill="url(#plate)" stroke="#D9DDE4" stroke-width="2"/>'
    else:
        ground = '<rect width="1024" height="1024" fill="#FFFFFF"/>'
        plate = '<rect x="14" y="14" width="996" height="996" rx="222" fill="url(#plate)" stroke="#D9DDE4" stroke-width="2" filter="url(#plateShadow)"/>'

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
 <defs>
  <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1">
   <stop offset="0" stop-color="#FFFFFF"/>
   <stop offset="1" stop-color="#E9ECF1"/>
  </linearGradient>
  <linearGradient id="green" gradientUnits="userSpaceOnUse" x1="0" y1="360" x2="0" y2="664">
   <stop offset="0" stop-color="#5BE6A2"/>
   <stop offset="1" stop-color="#22C474"/>
  </linearGradient>
  <filter id="plateShadow" x="-10%" y="-10%" width="120%" height="120%">
   <feDropShadow dx="0" dy="4" stdDeviation="6" flood-color="#1F242E" flood-opacity="0.12"/>
  </filter>
  <filter id="lift" x="-20%" y="-20%" width="140%" height="140%">
   <feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#1F242E" flood-opacity="0.18"/>
  </filter>
 </defs>
 {ground}
 {plate}{BRACES}
 <g filter="url(#lift)">{mark}
 </g>
</svg>
"""


def render(source: pathlib.Path, scratch: pathlib.Path) -> pathlib.Path:
    """`source` at 1024 px, on a transparent ground wherever it draws none."""
    page = scratch / (source.stem + ".html")
    page.write_text(
        "<!doctype html><html><body style='margin:0;background:transparent'>"
        f"<img src='{source.as_uri()}' width='1024' height='1024' style='display:block'>"
        "</body></html>"
    )
    full = scratch / (source.stem + ".png")
    subprocess.run(
        [
            CHROME,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            "--default-background-color=00000000",
            "--window-size=1024,1024",
            f"--user-data-dir={scratch / 'chrome'}",
            f"--screenshot={full}",
            page.as_uri(),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return full


def scaled(full: pathlib.Path, side: int, destination: pathlib.Path) -> None:
    subprocess.run(
        ["sips", "-s", "format", "png", "-Z", str(side), str(full), "--out", str(destination)],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def write_image_set(name: str, stem: str, full: pathlib.Path) -> None:
    folder = ASSETS / f"{name}.imageset"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    images = []
    for scale in (1, 2, 3):
        file = f"{stem}@{scale}x.png"
        scaled(full, ASSET_POINTS * scale, folder / file)
        images.append({"filename": file, "idiom": "universal", "scale": f"{scale}x"})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main() -> int:
    if not pathlib.Path(CHROME).exists():
        print(f"error: Chrome is not at {CHROME}", file=sys.stderr)
        return 69
    SOURCES.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="apelin-icons-"))
    try:
        for name, mark in MARKS.items():
            source = SOURCES / f"{name}.svg"
            source.write_text(svg(mark))
            destination = OUTPUT / f"{name}.png"
            scaled(render(source, scratch), SIZE, destination)
            print(destination.relative_to(ROOT))
        for asset, (name, stem) in PROJECT_ICONS.items():
            clear = scratch / f"{name}.clear.svg"
            clear.write_text(svg(MARKS[name], clear=True))
            write_image_set(asset, stem, render(clear, scratch))
            print(f"{(ASSETS / asset).relative_to(ROOT)}.imageset")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
