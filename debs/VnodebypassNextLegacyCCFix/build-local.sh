#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${SDK:-../iPhoneOS16.5.sdk}; LDID=${LDID:-/var/minis/skills/macho-signer/bin/ldid}
mkdir -p build
clang -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fblocks -fvisibility=hidden -Os -Wall -Wextra -Werror -Wno-unused-parameter -c VBModule.m -o build/VBModule.o
ld64.lld -arch arm64 -platform_version ios 15.0 16.5 -syslibroot "$SDK" -L"$SDK/usr/lib" -F"$SDK/System/Library/Frameworks" -bundle -undefined dynamic_lookup -dead_strip -x -o build/VBModule build/VBModule.o -lSystem -lobjc -framework UIKit -framework Foundation -framework IOKit
"$LDID" -S build/VBModule
file build/VBModule
