#!/var/jb/usr/bin/bash
#==========================================
# build-push.sh — 推送源码/deb 到 GitHub Actions 编译
# 支援 debs/*/ 多項目子目錄結構
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
TOTAL=9

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

step "扫描项目"
# 扫描子目录中的 Theos 项目
THEOS_PROJECTS=()
THEOS_DIRS=()
for dir in */; do
    dir="${dir%/}"
    mf="$DEBS_DIR/$dir/Makefile"
    if [ -f "$mf" ] && grep -qE "(TWEAK_NAME|TOOL_NAME|APPLICATION_NAME|SUBPROJECTS)" "$mf" 2>/dev/null; then
        THEOS_PROJECTS+=("$dir")
        THEOS_DIRS+=("$dir")
    fi
done

# 扫描根目录的 .deb 文件
DEB_FILES=()
for f in *.deb; do
    [ -f "$f" ] && DEB_FILES+=("$f")
done

echo ""
if [ "${#THEOS_PROJECTS[@]}" -gt 0 ]; then
    echo "  发现 ${#THEOS_PROJECTS[@]} 个 Theos 项目:"
    for p in "${THEOS_PROJECTS[@]}"; do
        name=$(grep "^TWEAK_NAME" "$DEBS_DIR/$p/Makefile" | head -1 | awk '{print $3}')
        ver=$(grep "^Version:" "$DEBS_DIR/$p/control" 2>/dev/null | awk '{print $2}')
        echo "    📦 $p (${name:-?} v${ver:-?})"
    done
fi
if [ "${#DEB_FILES[@]}" -gt 0 ]; then
    echo "  发现 ${#DEB_FILES[@]} 个 .deb 文件:"
    for f in "${DEB_FILES[@]}"; do
        echo "    📄 $f ($(du -h "$f" | cut -f1))"
    done
fi

if [ "${#THEOS_PROJECTS[@]}" -eq 0 ] && [ "${#DEB_FILES[@]}" -eq 0 ]; then
    echo "[错误] debs/ 为空或结构异常"
    echo "  请放入:"
    echo "    • Theos 项目子目录: debs/YourTweak/Makefile"
    echo "    • .deb 文件: debs/your-tweak.deb"
    exit 1
fi

cd "$SCRIPT_DIR"

step "检查 git 仓库"
if [ ! -d ".git" ]; then
    echo "[错误] 不是 Git 仓库，请先 git init"
    exit 1
fi
echo "  Git 仓库正常"

step "检测有变更的项目"
# 逐个检查每个项目是否有未提交变更
CHANGED_PROJECTS=()
for p in "${THEOS_PROJECTS[@]}"; do
    PDIR="debs/$p"
    if ! git diff --quiet "$PDIR" 2>/dev/null || \
       ! git diff --cached --quiet "$PDIR" 2>/dev/null || \
       [ -n "$(git ls-files --others --exclude-standard "$PDIR")" ]; then
        CHANGED_PROJECTS+=("$p")
    fi
done
THEOS_PROJECTS=("${CHANGED_PROJECTS[@]}")
HAS_THEOS=${#THEOS_PROJECTS[@]}
HAS_DEB=${#DEB_FILES[@]}

if [ "$HAS_THEOS" -eq 0 ] && [ "$HAS_DEB" -eq 0 ]; then
    echo "  [提示] 没有项目有变更，无需推送"
    exit 0
fi

echo ""
if [ "$HAS_THEOS" -gt 0 ]; then
    echo "  有变更的 Theos 项目:"
    for p in "${THEOS_PROJECTS[@]}"; do
        echo "    📦 $p"
    done
fi
if [ "$HAS_DEB" -gt 0 ]; then
    echo "  待推送的 .deb 文件:"
    for f in "${DEB_FILES[@]}"; do
        echo "    📄 $f"
    done
fi

step "版本信息"
if [ "$HAS_THEOS" -gt 0 ]; then
    echo "  ┌─ 项目详情 ──────────────────────────────"
    for p in "${THEOS_PROJECTS[@]}"; do
        name=$(grep "^TWEAK_NAME\|^TOOL_NAME\|^APPLICATION_NAME" "$DEBS_DIR/$p/Makefile" | head -1 | awk '{print $3}')
        ver=$(grep "^Version:" "$DEBS_DIR/$p/control" 2>/dev/null | awk '{print $2}')
        arch=$(grep "^Architecture:" "$DEBS_DIR/$p/control" 2>/dev/null | awk '{print $2}')
        echo "  ├ $p"
        echo "  │  ├ Name: ${name:-?}"
        echo "  │  ├ Version: ${ver:-?}"
        echo "  │  ├ Architecture: ${arch:-iphoneos-arm}"
        twk=$(grep "^TWEAK_NAME\|^TOOL_NAME" "$DEBS_DIR/$p/Makefile" 2>/dev/null | head -3 | awk '{print $3}' | tr '\n' ' ')
        echo "  │  └ Targets: $twk"
        echo "  │"
    done
    echo "  └──────────────────────────────────────────"
    echo ""
    echo "  推送到 GitHub Actions 编译"
else
    echo "  ${DEB_FILES[*]}"
    echo ""
    echo "  推送到 GitHub"
fi

step "清理构建缓存"
CLEAN_COUNT=0
for p in "${THEOS_PROJECTS[@]}"; do
    PDIR="$DEBS_DIR/$p"
    CLEANED=0
    [ -d "$PDIR/.theos" ] && rm -rf "$PDIR/.theos/" && CLEANED=1
    [ -d "$PDIR/.swiftpm" ] && rm -rf "$PDIR/.swiftpm/" && CLEANED=1
    [ -d "$PDIR/packages" ] && rm -rf "$PDIR/packages/" && CLEANED=1
    [ "$CLEANED" -eq 1 ] && echo "  ✓ $p 缓存已清理" && ((CLEAN_COUNT++))
done
[ "$CLEAN_COUNT" -eq 0 ] && echo "  无缓存需要清理"
echo ""

step "清理旧项目和旧 deb"
REMOVED_COUNT=0
# 清除 debs/ 中非本次推送的其他项目源码
for dir in "$DEBS_DIR"/*/; do
    dir="${dir%/}"
    dirname="$(basename "$dir")"
    # 跳过 .gitkeep
    [ "$dirname" = ".gitkeep" ] && continue
    # 检查是否在本次变更列表中
    FOUND=0
    for p in "${THEOS_PROJECTS[@]}"; do
        if [ "$p" = "$dirname" ]; then
            FOUND=1
            break
        fi
    done
    if [ "$FOUND" -eq 0 ]; then
        echo "  ├ 移除旧项目: $dirname"
        git rm -rf "$DEBS_DIR/$dirname" 2>/dev/null || rm -rf "$DEBS_DIR/$dirname"
        ((REMOVED_COUNT++))
    fi
done

# 清除 packages/ 中旧的 deb 文件
OLD_DEB_COUNT=$(ls "$SCRIPT_DIR/packages/"*.deb 2>/dev/null | wc -l)
if [ "$OLD_DEB_COUNT" -gt 0 ]; then
    echo "  ├ 移除 $OLD_DEB_COUNT 个旧 deb 文件"
    rm -f "$SCRIPT_DIR/packages/"*.deb
fi

[ "$REMOVED_COUNT" -eq 0 ] && echo "  无残留项目需要清理"
echo ""

step "提交变更"
COMMIT_MSG=""
if [ "$HAS_THEOS" -gt 0 ] && [ "$HAS_DEB" -eq 0 ]; then
    # 只有源码项目
    PROJ_LIST=""
    for p in "${THEOS_PROJECTS[@]}"; do
        name=$(grep "^TWEAK_NAME\|^TOOL_NAME" "$DEBS_DIR/$p/Makefile" | head -1 | awk '{print $3}')
        PROJ_LIST="${PROJ_LIST}${name:-$p} "
    done
    COMMIT_MSG="chore: 推送源码 - ${PROJ_LIST}(CI 编译)"
elif [ "$HAS_DEB" -gt 0 ] && [ "$HAS_THEOS" -eq 0 ]; then
    # 只有 .deb 文件
    DEB_NAMES=""
    for f in "${DEB_FILES[@]}"; do
        DEB_NAMES="${DEB_NAMES}$f "
    done
    COMMIT_MSG="chore: 推送 deb - ${DEB_NAMES}"
else
    # 混合模式
    PARTS=""
    for p in "${THEOS_PROJECTS[@]}"; do
        PARTS="${PARTS}[$p] "
    done
    for f in "${DEB_FILES[@]}"; do
        PARTS="${PARTS}$f "
    done
    COMMIT_MSG="chore: 推送 - ${PARTS}"
fi

echo "  提交信息: $COMMIT_MSG"
echo "  执行 git add..."
# 只添加有变更的项目目录，不 git add -A
for p in "${THEOS_PROJECTS[@]}"; do
    git add "debs/$p"
    echo "    ✓ added debs/$p"
done
for f in "${DEB_FILES[@]}"; do
    git add "debs/$f"
    echo "    ✓ added debs/$f"
done
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
