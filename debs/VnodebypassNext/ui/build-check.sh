#!/bin/sh
set -eu
# Usage: sh ui/build-check.sh /absolute/path/iPhoneOS16.5.sdk [/tmp/vb-ui-build]
SDK=${1:?Pass the iPhoneOS SDK path}
OUT=${2:-/tmp/vb-ui-build}
UI=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLANG=${CLANG:-clang}
LD64=${LD64:-ld64.lld}
mkdir -p "$OUT/App.app" "$OUT/VBModule.bundle"
for NAME in App VBModule; do
    "$CLANG" -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fblocks \
        -Wall -Wextra -Werror -Wno-unused-parameter -c "$UI/$NAME.m" -o "$OUT/$NAME.o"
done
# This extracted SDK provides versioned .tbd files but omits the usual
# libobjc.tbd/libSystem.tbd aliases, so use their real names explicitly.
"$LD64" -arch arm64 -platform_version ios 15.0 16.5 -syslibroot "$SDK" \
    -L"$SDK/usr/lib" -o "$OUT/App.app/vnodebypass" "$OUT/App.o" \
    -framework UIKit -framework Foundation -framework CoreFoundation -lobjc.A -lSystem.B
"$LD64" -arch arm64 -platform_version ios 15.0 16.5 -syslibroot "$SDK" \
    -L"$SDK/usr/lib" -bundle -undefined dynamic_lookup \
    -o "$OUT/VBModule.bundle/VBModule" "$OUT/VBModule.o" \
    -framework UIKit -framework Foundation -framework CoreFoundation -lobjc.A -lSystem.B
cp "$UI/App-Info.plist" "$OUT/App.app/Info.plist"
printf '%s\n' "Compile/link passed. UNSIGNED outputs in $OUT" \
    'CC Info.plist and existing VBModule icon resources must be supplied by packaging.'
