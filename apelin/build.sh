#!/bin/sh
# 本机打包脚本：给 apelin_project_build 用，产出可安装的 CCSIM .deb
# （原 CCSIM 的 bundle + CCSIMTool + iOS 17 卡死守卫，一个包）。
# 正式发行包仍由 GitHub Actions（Theos）构建；这里只是让本机能编译、打包、验证。
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}" # roothide 上为空

src_dir="tweaks/CCSIM"
stage="$(mktemp -d "${TMPDIR:?}stage.XXXXXX")"
objdir="$(mktemp -d "${TMPDIR:?}obj.XXXXXX")"
trap 'rm -rf -- "${stage:?}" "${objdir:?}"' EXIT

# 1) 编译守卫 dylib
case "$APELIN_BOOTSTRAP" in
  roothide) archs="arm64e" ;;
  *)        archs="arm64 arm64e" ;;
esac

dylibs=""
for arch in $archs; do
  clang -arch "$arch" -dynamiclib -O2 -fno-objc-arc \
    -DAPELIN_BUILD_ID="\"$APELIN_BUILD_ID\"" \
    -install_name "${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries/CCSIMGuard.dylib" \
    -framework Foundation \
    -o "$objdir/CCSIMGuard-$arch.dylib" "$src_dir/Tweak.m"
  dylibs="$dylibs $objdir/CCSIMGuard-$arch.dylib"
done

# 2) 合并架构并签名
# shellcheck disable=SC2086
lipo -create $dylibs -output "$objdir/CCSIMGuard.dylib"
ldid -S "$objdir/CCSIMGuard.dylib"

# 3) 打包布局：守卫 dylib + 原 CCSIM 的 bundle 与工具
libdir="$stage${APELIN_PREFIX?}/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$libdir" "$stage/DEBIAN"
cp "$objdir/CCSIMGuard.dylib" "$libdir/CCSIMGuard.dylib"
cp "$src_dir/CCSIMGuard.plist" "$libdir/CCSIMGuard.plist"

# layout/ 里除 DEBIAN 之外的文件按前缀装；DEBIAN/ 下的维护者脚本进包的 DEBIAN
if [ -d "$src_dir/layout/DEBIAN" ]; then
  cp -RP "$src_dir/layout/DEBIAN/." "$stage/DEBIAN/"
fi
for d in "$src_dir"/layout/*/; do
  n=$(basename "$d")
  [ "$n" = DEBIAN ] && continue
  cp -RP "$d." "$stage${APELIN_PREFIX?}/$n"
done

for f in Package Version Name Author Maintainer Section Description Depends Conflicts Replaces; do
  v=$(sed -n "s/^$f: *//p" "$src_dir/control" | head -1)
  [ -n "$v" ] && printf '%s: %s\n' "$f" "$v" >> "$stage/DEBIAN/control"
done
printf 'Architecture: %s\n' "$APELIN_ARCHITECTURE" >> "$stage/DEBIAN/control"

# 4) 产出唯一的包
dpkg-deb -b --root-owner-group "$stage" "$APELIN_PACKAGE_DIR/" >/dev/null
dpkg-deb -c "$APELIN_PACKAGE_DIR"/*.deb
