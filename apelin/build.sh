#!/bin/sh
# 本机打包脚本：给 apelin_project_build 用，产出可安装的 CCSIMFix .deb。
# 正式发行包仍由 GitHub Actions（Theos）构建；这里只是让本机能编译、安装、验证。
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}" # roothide 上为空

src_dir="tweaks/CCSIMFix"
stage="$(mktemp -d "${TMPDIR:?}stage.XXXXXX")"
objdir="$(mktemp -d "${TMPDIR:?}obj.XXXXXX")"
trap 'rm -rf -- "${stage:?}" "${objdir:?}"' EXIT

# 1) 编译
case "$APELIN_BOOTSTRAP" in
  roothide) archs="arm64e" ;;
  *)        archs="arm64 arm64e" ;;
esac

dylibs=""
for arch in $archs; do
  clang -arch "$arch" -dynamiclib -O2 -fno-objc-arc \
    -DAPELIN_BUILD_ID="\"$APELIN_BUILD_ID\"" \
    -install_name "${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries/CCSIMFix.dylib" \
    -framework Foundation \
    -o "$objdir/CCSIMFix-$arch.dylib" "$src_dir/Tweak.m"
  dylibs="$dylibs $objdir/CCSIMFix-$arch.dylib"
done

# 2) 合并架构并签名
# shellcheck disable=SC2086
lipo -create $dylibs -output "$objdir/CCSIMFix.dylib"
ldid -S "$objdir/CCSIMFix.dylib"

# 3) 打包布局
libdir="$stage${APELIN_PREFIX?}/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$libdir" "$stage/DEBIAN"
cp "$objdir/CCSIMFix.dylib" "$libdir/CCSIMFix.dylib"
cp "$src_dir/CCSIMFix.plist" "$libdir/CCSIMFix.plist"

for f in Package Version Name Author Maintainer Section Description Depends; do
  v=$(sed -n "s/^$f: *//p" "$src_dir/control" | head -1)
  [ -n "$v" ] && printf '%s: %s\n' "$f" "$v" >> "$stage/DEBIAN/control"
done
printf 'Architecture: %s\n' "$APELIN_ARCHITECTURE" >> "$stage/DEBIAN/control"

chmod -R go=rX "$libdir"

# 4) 产出唯一的包
dpkg-deb -b --root-owner-group "$stage" "$APELIN_PACKAGE_DIR/" >/dev/null
ls -l "$APELIN_PACKAGE_DIR"
