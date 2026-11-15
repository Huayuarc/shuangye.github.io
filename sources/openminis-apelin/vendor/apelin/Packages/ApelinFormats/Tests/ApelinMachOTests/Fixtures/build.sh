#!/usr/bin/env bash
# Rebuilds binaries/ from fixture.c. The outputs are committed so the tests
# need no compiler; rerun this only to change a fixture, then update the
# expectations in MachOImageTests (a different toolchain gives different UUIDs).
#
#   ios-arm64.dylib   thin arm64 iOS 16.0 dylib: install name, rpath, a weak
#                     framework, ad-hoc signed by ldid with entitlements
#   macos-fat         arm64 + x86_64 macOS 13.0 executable, ad-hoc signed
#   ios-arm64e-unsigned  thin arm64e iOS 16.0 executable, no signature
#   ios-arm64e-plain-binds     pointer-auth.c linked by CLT 15.0's ld with
#                              -undefined dynamic_lookup: plain dyld opcodes
#   ios-arm64e-threaded-binds  the same by CLT 15.3's ld: threaded binds
#
# The last two need those releases' own linkers (Apple products 042-32697
# and 052-59890, expanded with pkgutil): set CLT_15_0 and CLT_15_3 to their
# usr/bin to make them again; without them the committed ones are kept.

set -Eeuo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
out="$here/binaries"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/apelin-macho-fixture.XXXXXX")"
trap 'rm -rf -- "${scratch:?}"' EXIT
mkdir -p "$out"

ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
mac_sdk="$(xcrun --sdk macosx --show-sdk-path)"
# No build path in a committed binary.
flags=(-Os -g0 -ffile-prefix-map="$here"=. -Wl,-dead_strip)

xcrun clang -target arm64-apple-ios16.0 -isysroot "$ios_sdk" "${flags[@]}" \
    -dynamiclib -install_name @rpath/ApelinFixture.dylib \
    -Wl,-rpath,@loader_path/Frameworks -weak_framework CoreFoundation \
    "$here/fixture.c" -o "$scratch/ios-arm64.dylib"
xcrun strip -x "$scratch/ios-arm64.dylib"
cat >"$scratch/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>wiki.qaq.apelin.fixture</key>
	<true/>
</dict>
</plist>
PLIST
# ldid, as Scripts/package-deb.sh signs: codesign drops entitlements on a dylib.
ldid -S"$scratch/entitlements.plist" -Cadhoc -Iwiki.qaq.apelin.fixture "$scratch/ios-arm64.dylib"
cp "$scratch/ios-arm64.dylib" "$out/ios-arm64.dylib"

for arch in arm64 x86_64; do
    xcrun clang -target "$arch-apple-macos13.0" -isysroot "$mac_sdk" "${flags[@]}" -DFIXTURE_MAIN \
        -framework CoreFoundation "$here/fixture.c" -o "$scratch/macos-$arch"
done
xcrun lipo -create "$scratch/macos-arm64" "$scratch/macos-x86_64" -output "$scratch/macos-fat"
xcrun strip -x "$scratch/macos-fat"
codesign -f -s - "$scratch/macos-fat"
cp "$scratch/macos-fat" "$out/macos-fat"

xcrun clang -target arm64e-apple-ios16.0 -isysroot "$ios_sdk" "${flags[@]}" -DFIXTURE_MAIN \
    -framework CoreFoundation -Wl,-no_adhoc_codesign "$here/fixture.c" -o "$scratch/ios-arm64e-unsigned"
xcrun strip -x "$scratch/ios-arm64e-unsigned"
cp "$scratch/ios-arm64e-unsigned" "$out/ios-arm64e-unsigned"

sysroot="$scratch/sysroot"
mkdir -p "$sysroot/usr/lib"
cat >"$sysroot/usr/lib/libSystem.tbd" <<'TBD'
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64e-ios ]
install-name:    '/usr/lib/libSystem.B.dylib'
exports:
  - targets:         [ arm64e-ios ]
    symbols:         [ dyld_stub_binder ]
...
TBD
for pair in "${CLT_15_0:-}:plain" "${CLT_15_3:-}:threaded"; do
    bin="${pair%:*}" name="ios-arm64e-${pair##*:}-binds"
    [[ -n "$bin" ]] || continue
    "$bin/clang" -target arm64e-apple-ios16.0 -isysroot "$sysroot" "${flags[@]}" \
        -dynamiclib -install_name @rpath/ApelinFixture.dylib -Wl,-undefined,dynamic_lookup \
        "$here/pointer-auth.c" -o "$scratch/$name"
    cp "$scratch/$name" "$out/$name"
done

ls -l "$out"
