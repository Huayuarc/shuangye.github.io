#!/var/jb/usr/bin/bash
#==========================================
# build-push.sh — 推送 Theos 项目源码到 GitHub Actions 编译
# 用法: 在 Filza 中点击执行，或终端直接运行
#==========================================

set -e
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

echo "============================================"
echo "  GitHub Actions 推送脚本"
echo "  目录: $SCRIPT_DIR"
echo "  时间: $TIMESTAMP"
echo "============================================"
echo ""

DEBS_DIR="$SCRIPT_DIR/debs"
[ -d "$DEBS_DIR" ] || { echo "[错误] debs/ 目录不存在!"; exit 1; }
cd "$DEBS_DIR"

#=== 处理 git safe.directory ===
if ! GIT_TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
    GIT_ERR=$(git rev-parse --show-toplevel 2>&1)
    GIT_PATH=$(echo "$GIT_ERR" | grep -o "dubious ownership in repository at '[^']*'" | sed "s/^.*at '//;s/'$//")
    [ -n "$GIT_PATH" ] && git config --global --add safe.directory "$GIT_PATH" 2>/dev/null
fi

#=== 判断项目类型 ===
HAS_THEOS=""
if [ -f "Makefile" ] && grep -qE "(TWEAK_NAME|TOOL_NAME|APPLICATION_NAME|SUBPROJECTS)" Makefile 2>/dev/null; then
    HAS_THEOS="yes"
fi

HAS_DEB=$(ls *.deb 2>/dev/null | head -1)

if [ -z "$HAS_DEB" ] && [ -z "$HAS_THEOS" ]; then
    echo "[错误] debs/ 为空，请放入 .deb 文件或 Theos 项目源码"
    exit 1
fi

#=== 显示项目信息 ===
PROJ_NAME=""
if [ -n "$HAS_THEOS" ]; then
    PROJ_NAME=$(grep "^TWEAK_NAME" Makefile | head -1 | awk '{print $3}')
    [ -z "$PROJ_NAME" ] && PROJ_NAME=$(grep "^SUBPROJECTS" Makefile | head -1 | awk '{print $3}')
    [ -z "$PROJ_NAME" ] && PROJ_NAME="$(basename "$DEBS_DIR")"
    VERSION=$(grep "^Version:" control 2>/dev/null | awk '{print $2}') || VERSION="?"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Theos 项目: $PROJ_NAME v$VERSION"
    echo "  推送到 GitHub Actions 编译"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 清理构建缓存
    rm -rf .theos/ .swiftpm/ 2>/dev/null || true
else
    echo "[信息] 推送 ${HAS_DEB} 个 deb:"
    for f in *.deb; do
        echo "  • $(basename "$f") ($(du -h "$f" | cut -f1))"
    done
fi
echo ""

cd "$SCRIPT_DIR"

#=== 检查 git 仓库 ===
if [ ! -d ".git" ]; then
    echo "[错误] 不是 Git 仓库，请先 git init"
    exit 1
fi

#=== 检查是否有变更 ===
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard -- debs/)" ]; then
    echo "[提示] 没有新的变更需要提交"
    exit 0
fi

#=== 提交 ===
COMMIT_MSG=""
if [ -n "$HAS_THEOS" ]; then
    COMMIT_MSG="chore: 推送 $PROJ_NAME 源码（CI 编译）"
else
    DEB_NAMES=$(ls "$DEBS_DIR"/*.deb 2>/dev/null | xargs -I{} basename {} | tr '\n' ', ' | sed 's/, $//')
    COMMIT_MSG="chore: 推送 deb - ${DEB_NAMES}"
fi

echo "[提交] $COMMIT_MSG"
git add -A debs/
git commit -m "$COMMIT_MSG"

#=== 推送 ===
echo ""
echo "[推送] 正在推送到 GitHub..."
if git push 2>&1; then
    echo ""
    echo "============================================"
    echo "  推送成功！GitHub Actions 将自动编译"
    echo "============================================"
    echo ""
    echo "  查看构建状态:"
    echo "  https://github.com/Huayuarc/shuangye.github.io/actions"
else
    echo "[错误] 推送失败"
    exit 1
fi
