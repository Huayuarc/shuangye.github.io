#!/var/usr/bin/bash
#==========================================
# pull-debs.sh — 从 GitHub 拉取最新 deb 包到本地
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
echo "  从 GitHub 拉取最新 deb 包"
echo "  目录: $SCRIPT_DIR"
echo "  时间: $TIMESTAMP"
echo "============================================"
echo ""

# 解析项目参数
PROJECT_NAME=""
if [ $# -ge 1 ]; then
    PROJECT_NAME="$1"
    echo "  指定项目: $PROJECT_NAME"
    echo ""
fi

TOTAL=3

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

step "从 GitHub 拉取最新提交"
log "正在连接 GitHub..."
echo "  (拉取可能需要几十秒，请耐心等待)"
echo ""
if git pull 2>&1; then
    echo ""
    log "拉取成功"
else
    echo "[错误] 拉取失败，请检查网络连接"
    log "[错误] git pull 失败"
    exit 1
fi

step "查找本地 deb 包"
echo ""
DEB_FOUND=0
INSTALL_CMDS=""
for DEB_DIR in "debs" "packages"; do
    DEB_PATH="$SCRIPT_DIR/$DEB_DIR"
    [ -d "$DEB_PATH" ] || continue

    # 收集匹配的 deb
    MATCHED_DEBS=()
    for f in "$DEB_PATH"/*.deb; do
        [ -f "$f" ] || continue
        fname="$(basename "$f")"
        if [ -n "$PROJECT_NAME" ]; then
            # 按项目名过滤: 包名转为小写后匹配项目名
            fname_lower="$(echo "$fname" | tr '[:upper:]' '[:lower:]')"
            proj_lower="$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')"
            case "$fname_lower" in
                *"$proj_lower"*)
                    MATCHED_DEBS+=("$f")
                    ;;
            esac
        else
            MATCHED_DEBS+=("$f")
        fi
    done

    DEB_COUNT=${#MATCHED_DEBS[@]}
    if [ "$DEB_COUNT" -gt 0 ]; then
        echo "  ┌─ 目录: $DEB_DIR/ ($DEB_COUNT 个 deb 包)"
        for f in "${MATCHED_DEBS[@]}"; do
            echo "  ├─ $(basename "$f")  ($(du -h "$f" | cut -f1))"
            INSTALL_CMDS="${INSTALL_CMDS}dpkg -i \"$f\" && "
        done
        DEB_FOUND=$((DEB_FOUND + DEB_COUNT))
        echo "  └─"
        echo ""
    else
        if [ -n "$PROJECT_NAME" ]; then
            echo "  $DEB_DIR/ 目录下无匹配 [$PROJECT_NAME] 的 deb"
        else
            echo "  $DEB_DIR/ 目录存在但无 deb 文件"
        fi
    fi
done

if [ "$DEB_FOUND" -eq 0 ]; then
    echo ""
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║  暂无 deb 包                                  ║"
    echo "  ║                                               ║"
    echo "  ║  ─── 首次使用? ───                             ║"
    echo "  ║  1. 把插件源码放入 debs/ 目录                  ║"
    echo "  ║  2. 运行 build-push.sh 推送到 GitHub Actions   ║"
    echo "  ║  3. 等 CI 编译完成(约1~3分钟)                  ║"
    echo "  ║  4. 运行 pull-debs.sh <项目名> 拉取 deb       ║"
    echo "  ║                                               ║"
    echo "  ║  CI 状态:                                     ║"
    echo "  ║  https://github.com/Huayuarc/shuangye.github.io/actions  ║"
    echo "  ╚═══════════════════════════════════════════════╝"
else
    echo "  ┌─ 安装命令 ───────────────────────────────"
    echo "  │"
    # 移除末尾的 && 并显示安装命令
    INSTALL_CMD="${INSTALL_CMDS% && }"
    echo "  │  $INSTALL_CMD"
    echo "  │"
    echo "  └──────────────────────────────────────────"
fi

echo ""
echo "  $(date '+%Y-%m-%d %H:%M:%S') 全部完成"
