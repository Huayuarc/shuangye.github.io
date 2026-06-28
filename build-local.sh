#!/var/jb/usr/bin/bash
#==========================================
# build-local.sh — 本地编译 Theos 项目（rootless + roothide）
# 用法: bash build-local.sh <项目目录名>
# 示例: bash build-local.sh CPU
#==========================================

set -e
export LC_ALL=C

log() {
    local msg="$*"
    printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$msg"
    printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$msg" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

echo "============================================"
echo "  CPUthermal 本地构建脚本"
echo "  目录: $SCRIPT_DIR"
echo "  时间: $TIMESTAMP"
echo "============================================"
echo ""

PROJ="${1:-CPU}"
PROJ_DIR="$SCRIPT_DIR/debs/$PROJ"
OUT_DIR="$SCRIPT_DIR/packages"

# 验证项目
[ -d "$PROJ_DIR" ] || { echo "[错误] 项目目录不存在: $PROJ_DIR"; exit 1; }
[ -f "$PROJ_DIR/Makefile" ] || { echo "[错误] $PROJ_DIR/Makefile 不存在"; exit 1; }

PROJ_NAME=$(grep "^TWEAK_NAME\|^TOOL_NAME\|^APPLICATION_NAME" "$PROJ_DIR/Makefile" | head -1 | awk '{print $3}')
VERSION=$(grep "^Version:" "$PROJ_DIR/control" 2>/dev/null | awk '{print $2}') || VERSION="?"
echo "  项目: $PROJ_NAME v$VERSION"
echo ""

mkdir -p "$OUT_DIR"

# ==========================================
# 1. 编译 rootless (arm64)
# ==========================================
echo "━━━ [1/2] 编译 rootless (arm64) ━━━"
cd "$PROJ_DIR"

export THEOS=/var/mobile/theos
export ARCHS="arm64 arm64e"

make clean 2>/dev/null || true
if make FINALPACKAGE=1 2>&1 && make package FINALPACKAGE=1 2>&1; then
    DEB_COUNT=0
    for deb in packages/*.deb; do
        [ -f "$deb" ] || continue
        cp "$deb" "$OUT_DIR/"
        echo "  ✓ 已复制: $(basename "$deb") ($(du -h "$deb" | cut -f1))"
        ((DEB_COUNT++))
    done
    [ "$DEB_COUNT" -gt 0 ] && echo "  rootless 完成" || echo "  ⚠ 未产出 deb"
else
    echo "  ✗ rootless 编译失败"
fi

# ==========================================
# 2. 编译 roothide (arm64e)
# ==========================================
echo ""
echo "━━━ [2/2] 编译 roothide (arm64e) ━━━"

make clean 2>/dev/null || true
if make SCHEME=roothide FINALPACKAGE=1 2>&1 && make SCHEME=roothide package FINALPACKAGE=1 2>&1; then
    DEB_COUNT=0
    for deb in packages/*.deb; do
        [ -f "$deb" ] || continue
        cp "$deb" "$OUT_DIR/"
        echo "  ✓ 已复制: $(basename "$deb") ($(du -h "$deb" | cut -f1))"
        ((DEB_COUNT++))
    done
    [ "$DEB_COUNT" -gt 0 ] && echo "  roothide 完成" || echo "  ⚠ 未产出 deb"
else
    echo "  ✗ roothide 编译失败（可忽略，仅 rootless 可用）"
fi

# ==========================================
# 3. 清理项目级缓存
# ==========================================
rm -rf "$PROJ_DIR/.theos/" "$PROJ_DIR/packages/" 2>/dev/null || true

# ==========================================
# 4. 汇总
# ==========================================
echo ""
echo "━━━ 构建汇总 ━━━"
cd "$SCRIPT_DIR"
TOTAL_SIZE=0
for deb in "$OUT_DIR"/*.deb; do
    [ -f "$deb" ] || continue
    SIZE=$(du -h "$deb" | cut -f1)
    echo "  📦 $(basename "$deb")  ($SIZE)"
done

DEB_COUNT=$(ls "$OUT_DIR"/*.deb 2>/dev/null | wc -l)
echo "  共 $DEB_COUNT 个 deb 包"
echo ""
echo "  推送命令: bash build-push.sh"
echo ""
echo "  $(date '+%Y-%m-%d %H:%M:%S') 全部完成"
