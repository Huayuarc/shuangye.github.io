#!/bin/bash
# Rebuilds the code-signing fixtures beside this script. Not part of any
# build: the results are committed, and this is how they were made.
#
#   input/     built here from fixture.c with Xcode's iPhoneOS SDK: what
#              apelin-build has after strip, the linker's own ad-hoc
#              signature still in place (or none, -no_adhoc_codesign).
#   expected/  the same files after `ldid -Hsha256 -S` (or `-S<file>` with
#              entitlements.plist), the signature ApelinCodeSign writes.
#              The tests compare the signer's output with these byte for
#              byte. ldid is procursus's (`ldid` 2.1.5-procursus7 here),
#              the same tool the device-side research signed with.
#
# usage: build.sh   (needs xcrun with the iPhoneOS SDK, and ldid on PATH)
set -euo pipefail
cd "$(dirname "$0")"
CC="xcrun --sdk iphoneos clang -mios-version-min=16.0 -Os -fvisibility=hidden"
WORK=$(mktemp -d /private/tmp/apelin-codesign-fixtures.XXXXXX)
trap 'rm -rf -- "${WORK:?}"' EXIT
mkdir -p "$WORK/input" "$WORK/expected"

cat >"$WORK/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.example.fixture</string>
</dict>
</plist>
EOF

# a tweak as apelin-build makes it: fat, rootless's two slices
$CC -arch arm64 -arch arm64e fixture.c -dynamiclib -install_name @rpath/Fixture.dylib -o "$WORK/input/Fixture.dylib"
# roothide's single slice, thin
$CC -arch arm64e fixture.c -dynamiclib -install_name @rpath/Thin.dylib -o "$WORK/input/Thin.dylib"
# never signed by the linker: the signer adds the load command
$CC -arch arm64 fixture.c -dynamiclib -Wl,-no_adhoc_codesign -install_name @rpath/Unsigned.dylib -o "$WORK/input/Unsigned.dylib"
# a preference bundle
$CC -arch arm64 -arch arm64e fixture.c -bundle -o "$WORK/input/FixtureBundle"
# a command-line tool with no entitlements, and one with
$CC -arch arm64 -arch arm64e -DFIXTURE_EXECUTABLE fixture.c -o "$WORK/input/fixture-tool"
cp "$WORK/input/fixture-tool" "$WORK/input/fixture-tool-entitled"
# an app's program: fat, an __info_plist section for the info slot, entitlements
$CC -arch arm64 -arch arm64e -DFIXTURE_EXECUTABLE fixture.c \
    -Wl,-sectcreate,__TEXT,__info_plist,"$WORK/Info.plist" -o "$WORK/input/FixtureApp"
# stripped as the build strips (-x), after the linker signed it
for f in "$WORK"/input/*; do xcrun strip -x "$f" 2>/dev/null || true; done

cp "$WORK"/input/* "$WORK/expected/"
for f in Fixture.dylib Thin.dylib Unsigned.dylib FixtureBundle fixture-tool; do
    ldid -Hsha256 -S "$WORK/expected/$f"
done
for f in fixture-tool-entitled FixtureApp; do
    ldid -Hsha256 -Sentitlements.plist "$WORK/expected/$f"
done

rm -rf input expected
cp -R "$WORK/input" "$WORK/expected" .
ls -l input expected
