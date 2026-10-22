#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${SDK:-../iPhoneOS16.5.sdk}; LDID=${LDID:-/var/minis/skills/macho-signer/bin/ldid}
mkdir -p build
for A in arm64 arm64e; do
 clang -target "$A-apple-ios15.0" -isysroot "$SDK" -fobjc-arc -fblocks -fvisibility=hidden -Os -Wall -Wextra -Werror -Wno-unused-parameter -c VBModule.m -o "build/VBModule.$A.o"
done
# Alpine ld64.lld lowers arm64e output to arm64; Xcode ld in CI preserves PAC00.
ld64.lld -arch arm64 -platform_version ios 15.0 16.5 -syslibroot "$SDK" -L"$SDK/usr/lib" -F"$SDK/System/Library/Frameworks" -bundle -undefined dynamic_lookup -dead_strip -x -o build/VBModule.arm64 build/VBModule.arm64.o -lSystem -lobjc -framework UIKit -framework Foundation -framework IOKit
"$LDID" -S build/VBModule.arm64
file build/VBModule.arm64.o build/VBModule.arm64e.o build/VBModule.arm64
llvm-otool -hv build/VBModule.arm64e.o
