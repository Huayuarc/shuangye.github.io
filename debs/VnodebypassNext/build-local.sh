#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${SDK:-../iPhoneOS16.5.sdk}
LDID=${LDID:-/var/minis/skills/macho-signer/bin/ldid}
mkdir -p build
CFLAGS="-target arm64-apple-ios15.0 -isysroot $SDK -fobjc-arc -fblocks -fvisibility=hidden -Os -Wall -Wextra -Wno-unused-parameter"
# System framework declarations come from the Apple SDK, no fake headers.
clang $CFLAGS -c core/Controller.m -o build/Controller.o
clang $CFLAGS -c core/kernel.m -o build/kernel.o
clang -target arm64-apple-ios15.0 -isysroot "$SDK" -Os -c core/fishhook.c -o build/fishhook.o
ld64.lld -arch arm64 -platform_version ios 15.0 16.5 -syslibroot "$SDK" -L"$SDK/usr/lib" -F"$SDK/System/Library/Frameworks" -dead_strip -x -o build/vnodebypass build/Controller.o build/kernel.o build/fishhook.o -lSystem -lobjc -framework Foundation -framework CoreFoundation -framework IOKit
"$LDID" -Shelper-entitlements.plist build/vnodebypass
if [ -f ui/App.m ]; then
 clang $CFLAGS -c ui/App.m -o build/App.o
 ld64.lld -arch arm64 -platform_version ios 15.0 16.5 -syslibroot "$SDK" -L"$SDK/usr/lib" -F"$SDK/System/Library/Frameworks" -dead_strip -x -o build/App build/App.o -lSystem -lobjc -framework UIKit -framework Foundation -framework CoreGraphics
 "$LDID" -Sapp-entitlements.plist build/App
fi
if [ -f ui/VBModule.m ]; then
 clang $CFLAGS -c ui/VBModule.m -o build/VBModule.o
 ld64.lld -arch arm64 -platform_version ios 15.0 16.5 -syslibroot "$SDK" -L"$SDK/usr/lib" -F"$SDK/System/Library/Frameworks" -bundle -undefined dynamic_lookup -dead_strip -x -o build/VBModule build/VBModule.o -lSystem -lobjc -framework UIKit -framework Foundation
 "$LDID" -S build/VBModule
fi
