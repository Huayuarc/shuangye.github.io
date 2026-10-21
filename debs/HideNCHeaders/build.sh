#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${SDK:-/opt/ios-sdk/iPhoneOS16.5.sdk}
LLVMROOT=${LLVMROOT:-/opt/cpu-llvm21}
APPLE_ROOT=${APPLE_ROOT:-/opt/cpu-apple}
GLIBC_ROOT=${GLIBC_ROOT:-/opt/cpu-glibc}
VERSION=1.0.5
export SOURCE_DATE_EPOCH=1792396800
export LC_ALL=C
mkdir -p build dist
llvmclang() {
    "$LLVMROOT/lib/ld-musl-aarch64.so.1" \
      --library-path "$LLVMROOT/usr/lib:$LLVMROOT/lib" \
      "$LLVMROOT/usr/bin/clang" \
      -resource-dir "$LLVMROOT/usr/lib/llvm21/lib/clang/21" "$@"
}
appletool() {
    tool=$1; shift
    "$GLIBC_ROOT/lib/ld-linux-aarch64.so.1" \
      --library-path "$GLIBC_ROOT/lib/aarch64-linux-gnu:$GLIBC_ROOT/usr/lib/aarch64-linux-gnu:$GLIBC_ROOT/lib" \
      "$APPLE_ROOT/linux/iphone/bin/$tool" "$@"
}
for arch in arm64 arm64e; do
    llvmclang -target "$arch-apple-ios16.0" -isysroot "$SDK" \
      -fobjc-arc -fblocks -Oz -fvisibility=hidden -Wall -Wextra -Werror \
      -c HideNCHeaders.m -o "build/$arch.o"
    appletool ld -arch "$arch" -dylib -platform_version ios 16.0 16.5 \
      -syslibroot "$SDK" -o "build/$arch.dylib" "build/$arch.o" \
      -framework Foundation -framework UIKit \
      -F"$SDK/System/Library/PrivateFrameworks" -framework UserNotificationsUIKit -lobjc -lSystem \
      -install_name '@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/HideNCHeaders.dylib' \
      -dead_strip
    # Strip before signing; no post-sign binary modifications.
    appletool strip -S -x "build/$arch.dylib"
done
llvm-lipo -create build/arm64.dylib build/arm64e.dylib -output build/HideNCHeaders.dylib
ldid -S build/HideNCHeaders.dylib
STAGE=build/package
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/Library/MobileSubstrate/DynamicLibraries"
cp control "$STAGE/DEBIAN/control"
cp HideNCHeaders.plist "$STAGE/Library/MobileSubstrate/DynamicLibraries/"
cp build/HideNCHeaders.dylib "$STAGE/Library/MobileSubstrate/DynamicLibraries/"
chmod 0755 "$STAGE/Library/MobileSubstrate/DynamicLibraries/HideNCHeaders.dylib"
chmod 0644 "$STAGE/Library/MobileSubstrate/DynamicLibraries/HideNCHeaders.plist" "$STAGE/DEBIAN/control"
find "$STAGE" -type d -exec chmod 0755 {} +
# No maintainer script: installation/removal cannot execute arbitrary shell actions.
dpkg-deb --root-owner-group -Zxz -z9 --build "$STAGE" \
    "dist/HideNCHeaders_${VERSION}_arm64_arm64e_roothide.deb"
python3 tests/run_runtime_test.py > build/runtime_test.txt
cat build/runtime_test.txt
python3 verify.py
python3 - <<'PY'
import pathlib, zipfile
root = pathlib.Path('.')
files = ['HideNCHeaders.m', 'HNCSpacing.h', 'HNCViewFallback.h', 'HNCFooterControls.h', 'HNCFooterSpacing.h', 'HideNCHeaders.plist', 'control', 'Makefile',
         'build.sh', 'verify.py', 'README.md', 'LICENSE', 'verification.md',
         'tests/run_runtime_test.py']
with zipfile.ZipFile('dist/HideNCHeaders_1.0.5_source.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name in files:
        z.write(root / name, 'HideNCHeaders/' + name)
with zipfile.ZipFile('dist/HideNCHeaders_1.0.5_source.zip') as z:
    assert z.testzip() is None
PY
sha256sum dist/HideNCHeaders_*.deb dist/HideNCHeaders_*.zip
