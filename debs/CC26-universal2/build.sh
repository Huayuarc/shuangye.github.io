#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <com.cureux.cc26_0.4.9.9b-nomedia3_precise.deb> [output.deb]" >&2
  exit 2
fi

INPUT="$1"
OUTPUT="${2:-com.cureux.cc26_0.6.0.0-universal1.deb}"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/root"
dpkg-deb -R "$INPUT" "$ROOT"

MAIN="$ROOT/Library/MobileSubstrate/DynamicLibraries/CC26.dylib"
python3 "$HERE/patch_cc26.py" "$MAIN" "$WORK/CC26.dylib.patched"
cp -f "$WORK/CC26.dylib.patched" "$MAIN"

cp -f "$HERE/control" "$ROOT/DEBIAN/control"
cp -f "$HERE/preinst" "$ROOT/DEBIAN/preinst"
cp -f "$HERE/postinst" "$ROOT/DEBIAN/postinst"
chmod 755 "$ROOT/DEBIAN/preinst" "$ROOT/DEBIAN/postinst"
mkdir -p "$ROOT/Library/CC26"
cp -f "$HERE/CC26-icon.png" "$ROOT/Library/CC26/icon.png"

MIRROR="$ROOT/var/mobile/Library/pkgmirror/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$MIRROR"
cp -f "$MAIN" "$MIRROR/CC26.dylib"
cp -f "$ROOT/Library/MobileSubstrate/DynamicLibraries/CC26.plist" "$MIRROR/CC26.plist"
rm -f "$MIRROR/CC26.dylib.roothidepatch"
ln -s /usr/lib/DynamicPatches/AutoPatches.dylib "$MIRROR/CC26.dylib.roothidepatch"
mkdir -p "$ROOT/var/mobile/Library/pkgmirror/DEBIAN.com.cureux.cc26"
cp -f "$HERE/pkgmirror-control" "$ROOT/var/mobile/Library/pkgmirror/DEBIAN.com.cureux.cc26/control"

rm -f "$ROOT/Library/MobileSubstrate/DynamicLibraries/CC26.dylib.roothidepatch"
ln -s /usr/lib/DynamicPatches/AutoPatches.dylib "$ROOT/Library/MobileSubstrate/DynamicLibraries/CC26.dylib.roothidepatch"

dpkg-deb -b "$ROOT" "$OUTPUT"
echo "built: $OUTPUT"
sha256sum "$MAIN" "$MIRROR/CC26.dylib" "$OUTPUT"
