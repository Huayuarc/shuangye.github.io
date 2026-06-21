#!/var/jb/usr/bin/bash
#==========================================
# pull-debs.sh — 从 GitHub 拉取最新 deb 包到本地
# 用法: 在 Filza 中点击执行，或终端直接运行
#==========================================

set -e
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

echo "============================================"
echo "  正在从 GitHub 拉取最新 deb 包..."
echo "  目录: $SCRIPT_DIR"
echo "============================================"

#=== 处理 git safe.directory ===
if ! GIT_TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
    GIT_ERR=$(git rev-parse --show-toplevel 2>&1)
    GIT_PATH=$(echo "$GIT_ERR" | grep -o "dubious ownership in repository at '[^']*'" | sed "s/^.*at '//;s/'$//")
    [ -n "$GIT_PATH" ] && git config --global --add safe.directory "$GIT_PATH" 2>/dev/null
fi

# 拉取最新提交
if git pull 2>&1; then
    echo ""
    echo "============================================"
    echo "  当前可用的 deb 包:"
    echo "============================================"
    if ls packages/*.deb 2>/dev/null; then
        echo ""
        echo "  已同步到: $SCRIPT_DIR/packages/"
    else
        echo "  (暂无 deb 包，请先推送 Theos 源码触发 CI 编译)"
    fi
    echo ""
    echo "安装命令:"
    echo "  dpkg -i $SCRIPT_DIR/packages/*.deb"
    echo ""
else
    echo "[错误] 拉取失败"
    exit 1
fi
