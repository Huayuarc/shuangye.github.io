#!/var/jb/usr/bin/bash
# ==============================================================
#  pull-debs.sh — 从 GitHub 拉取最新 deb 包到本地
#
#  用法: 直接运行，自动 git pull 获取 CI 编译好的 deb
# ==============================================================

set -e
export LC_ALL=C

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  正在从 GitHub 拉取最新 deb 包..."
echo "============================================"

cd "$REPO_DIR"

# 拉取最新提交
git pull

echo ""
echo "============================================"
echo "  当前可用的 deb 包:"
echo "============================================"

if ls packages/*.deb 2>/dev/null; then
    echo ""
    echo "✅ 已同步到: $REPO_DIR/packages/"
else
    echo "  (暂无 deb 包)"
fi

echo ""
echo "安装命令示例:"
echo "  dpkg -i $REPO_DIR/packages/*.deb"
echo ""
