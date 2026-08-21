#!/usr/bin/env bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$source_dir/.." && pwd)"
build_root="/tmp/perfectgrabber-roothide-build"
version="$(sed -n 's/^Version:[[:space:]]*//p' "$source_dir/control" | head -n 1 | tr -d '\r')"
test -n "$version"
build_number="${version##*roothide}"
[[ "$build_number" =~ ^[0-9]+$ ]]
release_name="Ntonia-PreferenceLoader-bate${build_number}_hide64e"
release_dir="$project_root/测试版/$release_name"
output="$release_dir/Ntonia-PreferenceLoader.deb"
archive="$release_dir/${release_name}.zip"

rm -rf "$build_root"
mkdir -p "$build_root"
cp -a "$source_dir/." "$build_root/"
rm -rf "$build_root/.theos" "$build_root/packages"
find "$build_root" -type d -exec chmod 0755 {} +
find "$build_root" -type f -exec chmod 0644 {} +
chmod 0755 "$build_root/build.sh" "$build_root/verify.sh"

export THEOS="${THEOS_ROOTHIDE:-$HOME/theos-roothide}"
test -d "$THEOS"
cd "$build_root"
make clean package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
deb="$(find packages -maxdepth 1 -type f -name '*.deb' -print -quit)"
test -f "$deb"

package_root="$build_root/package-root"
dpkg-deb -R "$deb" "$package_root"
allemande="${ALLEMANDE:-$HOME/.local/bin/allemande}"
ldid="$THEOS/toolchain/linux/iphone/bin/ldid"
test -x "$allemande"
test -x "$ldid"

binaries=(
    "$package_root/Library/MobileSubstrate/DynamicLibraries/PerfectGrabber.dylib"
    "$package_root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/PerfectGrabberSettings"
)
for binary in "${binaries[@]}"; do
    test -f "$binary"
    "$allemande" "$binary" "$binary.converted"
    chmod 0755 "$binary.converted"
    mv -f "$binary.converted" "$binary"
    "$ldid" -S "$binary"
done

sed -i 's/^Architecture:.*/Architecture: iphoneos-arm64e/' "$package_root/DEBIAN/control"
printf 'X-Package-Scheme: roothide\nX-Arm64e-ABI: allemande\n' >> "$package_root/DEBIAN/control"
mkdir -p "$release_dir" "$project_root/正式版"
fakeroot dpkg-deb -Zzstd -b "$package_root" "$output"
"$source_dir/verify.sh" "$output"
cp "$source_dir/更新日志.txt" "$release_dir/更新日志.txt"
hash="$(sha256sum "$output" | awk '{print toupper($1)}')"
printf '%s  %s\n' "$hash" "$(basename "$output")" > "$release_dir/SHA256.txt"
rm -f "$archive"
(cd "$release_dir" && zip -q -j "$(basename "$archive")" "$(basename "$output")")
echo "$hash  $output"
echo "Release: $release_dir"
