#!/usr/bin/env bash
set -euo pipefail

deb="${1:?Usage: verify.sh package.deb}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
dpkg-deb -R "$deb" "$work/root"

test -f "$work/root/Library/MobileSubstrate/DynamicLibraries/PerfectGrabber.dylib"
test -f "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/PerfectGrabberSettings"
test -f "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/NtoniaPGIcon.png"
test -f "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/NtoniaPGIcon@2x.png"
test -f "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/NtoniaPGIcon@3x.png"
test -f "$work/root/Library/PreferenceLoader/Preferences/PerfectGrabberSettings.plist"
test -f "$work/root/Library/PreferenceLoader/Preferences/NtoniaPGIcon.png"
! find "$work/root" -path '*/var/jb/*' -print -quit | grep -q .
grep -q '^Architecture: iphoneos-arm64e$' "$work/root/DEBIAN/control"
grep -q '^Icon: file:///Library/PreferenceBundles/PerfectGrabberSettings.bundle/.jbroot/Library/PreferenceBundles/PerfectGrabberSettings.bundle/NtoniaPGIcon.png$' "$work/root/DEBIAN/control"
python3 - "$work/root" <<'PY'
import plistlib
import sys

root = sys.argv[1]
paths = [
    root + "/Library/MobileSubstrate/DynamicLibraries/PerfectGrabber.plist",
    root + "/Library/PreferenceBundles/PerfectGrabberSettings.bundle/Info.plist",
    root + "/Library/PreferenceLoader/Preferences/PerfectGrabberSettings.plist",
]
for path in paths:
    with open(path, "rb") as stream:
        plistlib.load(stream)

with open(root + "/Library/PreferenceLoader/Preferences/PerfectGrabberSettings.plist", "rb") as stream:
    entry = plistlib.load(stream)["entry"]
assert entry["icon"] == "NtoniaPGIcon.png"
PY

file "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/NtoniaPGIcon.png" \
    | grep -q 'PNG image data, 29 x 29'
file "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/NtoniaPGIcon@2x.png" \
    | grep -q 'PNG image data, 58 x 58'
file "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/NtoniaPGIcon@3x.png" \
    | grep -q 'PNG image data, 87 x 87'

for binary in \
    "$work/root/Library/MobileSubstrate/DynamicLibraries/PerfectGrabber.dylib" \
    "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/PerfectGrabberSettings"; do
    file "$binary" | grep -q 'Mach-O'
    ! strings -a "$binary" | grep -q '/var/jb/var/mobile/Library/Preferences'
done

otool="$THEOS/toolchain/linux/iphone/bin/otool"
lipo="$THEOS/toolchain/linux/iphone/bin/lipo"
test -x "$otool"
test -x "$lipo"
for binary in \
    "$work/root/Library/MobileSubstrate/DynamicLibraries/PerfectGrabber.dylib" \
    "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/PerfectGrabberSettings"; do
    "$lipo" -info "$binary" | grep 'arm64 arm64e' >/dev/null
    ! "$otool" -L "$binary" | grep -F '/var/jb/' >/dev/null
done
"$otool" -L "$work/root/Library/MobileSubstrate/DynamicLibraries/PerfectGrabber.dylib" \
    | grep -F '@loader_path/.jbroot/usr/lib/libsubstrate.dylib' >/dev/null

strings -a "$work/root/Library/MobileSubstrate/DynamicLibraries/PerfectGrabber.dylib" \
    | grep -F 'com.netskao.perfectgrabber.settingschanged' >/dev/null
strings -a "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/PerfectGrabberSettings" \
    | grep -F 'CFPreferences' >/dev/null
! strings -a "$work/root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/PerfectGrabberSettings" \
    | grep -F 'PSListItemsController' >/dev/null
echo 'Static verification passed.'
