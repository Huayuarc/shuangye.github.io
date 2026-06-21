#!/var/jb/usr/bin/bash
#==========================================
# build-push.sh — 推送 Theos 项目源码到 GitHub Actions 编译
# 用法: 在 Filza 中点击执行，或终端直接运行
#==========================================

set -e
export LC_ALL=C

# 实时进度输出（兼容 Filza 脚本运行器：写 stderr 保证即时显示）
log() {
    local msg="$*"
    printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$msg"
    printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$msg" >&2
}

# 进度计数
STEP=0
step() {
    STEP=$((STEP + 1))
    echo ""
    echo "━━━ [$STEP/$TOTAL] $* ━━━"
    echo "━━━ [$STEP/$TOTAL] $* ━━━" >&2
}

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

# 先计算总步骤
TOTAL=7

step "处理 git safe.directory"
log "正在检查仓库权限..."
CURRENT_DIR=$(pwd)
if git rev-parse --show-toplevel 2>/dev/null; then
    log "仓库权限正常"
else
    log "检测到仓库权限问题，正在修复..."
    log "添加 safe.directory: $CURRENT_DIR"
    if git config --global --add safe.directory "$CURRENT_DIR" 2>&1; then
        log "修复完成"
    else
        log "[警告] git config --global 失败，尝试绕过权限检查..."
        export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:+$GIT_CONFIG_PARAMETERS }'safe.directory=$CURRENT_DIR'"
        log "已通过环境变量绕过权限检查"
    fi
    log "继续执行后续步骤..."
fi

step "判断项目类型"
HAS_THEOS=""
if [ -f "Makefile" ] && grep -qE "(TWEAK_NAME|TOOL_NAME|APPLICATION_NAME|SUBPROJECTS)" Makefile 2>/dev/null; then
    HAS_THEOS="yes"
    echo "  检测到 Theos 项目"
fi

HAS_DEB=$(ls *.deb 2>/dev/null | head -1)

if [ -z "$HAS_DEB" ] && [ -z "$HAS_THEOS" ]; then
    echo "[错误] debs/ 为空，请放入 .deb 文件或 Theos 项目源码"
    exit 1
fi
echo "  完成"

step "显示项目信息"
PROJ_NAME=""
if [ -n "$HAS_THEOS" ]; then
    PROJ_NAME=$(grep "^TWEAK_NAME" Makefile | head -1 | awk '{print $3}')
    [ -z "$PROJ_NAME" ] && PROJ_NAME=$(grep "^SUBPROJECTS" Makefile | head -1 | awk '{print $3}')
    [ -z "$PROJ_NAME" ] && PROJ_NAME="$(basename "$DEBS_DIR")"
    VERSION=$(grep "^Version:" control 2>/dev/null | awk '{print $2}') || VERSION="?"

    echo "  Theos 项目: $PROJ_NAME v$VERSION"
    echo "  推送到 GitHub Actions 编译"
    echo ""

    # 清理构建缓存
    echo "  清理构建缓存..."
    rm -rf .theos/ .swiftpm/ 2>/dev/null || true
    echo "  缓存已清理"
else
    echo "  推送 ${HAS_DEB} 个 deb:"
    for f in *.deb; do
        echo "    • $(basename "$f") ($(du -h "$f" | cut -f1))"
    done
fi

cd "$SCRIPT_DIR"

step "检查 git 仓库"
if [ ! -d ".git" ]; then
    echo "[错误] 不是 Git 仓库，请先 git init"
    exit 1
fi
echo "  Git 仓库正常"

step "检查是否有变更"
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard -- debs/)" ]; then
    echo "[提示] 没有新的变更需要提交"
    exit 0
fi
echo "  检测到有未提交的变更"

step "提交变更"
COMMIT_MSG=""
if [ -n "$HAS_THEOS" ]; then
    COMMIT_MSG="chore: 推送 $PROJ_NAME 源码（CI 编译）"
else
    DEB_NAMES=$(ls "$DEBS_DIR"/*.deb 2>/dev/null | xargs -I{} basename {} | tr '\n' ', ' | sed 's/, $//')
    COMMIT_MSG="chore: 推送 deb - ${DEB_NAMES}"
fi

echo "  提交信息: $COMMIT_MSG"
echo "  执行 git add..."
git add -A debs/
echo "  执行 git commit..."
if git commit -m "$COMMIT_MSG"; then
    echo "  提交成功"
else
    echo "  提交失败"
    exit 1
fi

step "推送到 GitHub"
log "正在连接 GitHub，准备推送..."
echo "  (推送可能需要几十秒，请耐心等待)"
echo ""
if git push 2>&1; then
    echo ""
    echo "============================================"
    echo "  推送成功！GitHub Actions 将自动编译"
    echo "============================================"
    log "推送成功"
    echo ""
    echo "  查看构建状态:"
    echo "  https://github.com/Huayuarc/shuangye.github.io/actions"
    echo ""
    echo "  $(date '+%Y-%m-%d %H:%M:%S') 全部完成"
else
    echo "[错误] 推送失败，详细错误如上"
    log "[错误] git push 失败"
    exit 1
fi
