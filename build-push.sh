#!/var/jb/usr/bin/bash
# ==============================================================
#  build-push.sh — 推送 Theos 项目源码到 GitHub Actions 编译
#
#  用法:
#    1. 将 .deb 文件 或 Theos 项目源码放入 debs/
#    2. 运行此脚本
#    3. 自动完成：git add → commit → push
#    4. GitHub Actions 自动编译并部署
# ==============================================================

set -e
export LC_ALL=C

# ── 颜色 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 路径 ──
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEBS_DIR="$REPO_DIR/debs"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  GitHub Actions 推送脚本${NC}"
echo -e "${CYAN}  $TIMESTAMP${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# ── 检查 Git 仓库 ──
if [ ! -d "$REPO_DIR/.git" ]; then
    echo -e "${RED}[错误] 这不是 Git 仓库根目录${NC}"
    exit 1
fi

# ── 检查 debs/ ──
if [ ! -d "$DEBS_DIR" ]; then
    echo -e "${YELLOW}[提示] 创建 debs/ 目录${NC}"
    mkdir -p "$DEBS_DIR"
    echo -e "${YELLOW}请将 .deb 文件或 Theos 项目放入: $DEBS_DIR${NC}"
    echo -e "${YELLOW}然后重新运行此脚本${NC}"
    exit 0
fi

cd "$DEBS_DIR"

# ── 判断类型 ──
HAS_DEB=$(ls *.deb 2>/dev/null | head -1)
HAS_THEOS=""
if [ -f "Makefile" ] && grep -qE "(TWEAK_NAME|TOOL_NAME|APPLICATION_NAME|SUBPROJECTS)" Makefile 2>/dev/null; then
    HAS_THEOS="yes"
fi

if [ -z "$HAS_DEB" ] && [ -z "$HAS_THEOS" ]; then
    echo -e "${RED}[错误] debs/ 为空，请放入 .deb 文件或 Theos 项目源码${NC}"
    exit 1
fi

# ── 显示项目信息 ──
PROJ_NAME=""
if [ -n "$HAS_THEOS" ]; then
    if grep -q "^TWEAK_NAME" Makefile 2>/dev/null; then
        PROJ_NAME=$(grep "^TWEAK_NAME" Makefile | head -1 | awk '{print $3}')
    fi
    if grep -q "^SUBPROJECTS" Makefile 2>/dev/null; then
        PROJ_NAME=$(grep "^SUBPROJECTS" Makefile | head -1 | awk '{print $3}')
    fi
    [ -z "$PROJ_NAME" ] && PROJ_NAME="$(basename "$DEBS_DIR")"

    VERSION="?"
    if [ -f "control" ]; then
        VERSION=$(grep "^Version:" control | awk '{print $2}')
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Theos 项目: $PROJ_NAME v$VERSION${NC}"
    echo -e "${CYAN}  推送到 GitHub Actions 编译${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi

# ── 列出要推送的内容 ──
if [ -n "$HAS_THEOS" ]; then
    echo -e "${GREEN}推送项目源码: $PROJ_NAME${NC}"
    # 清理构建缓存（不上传）
    rm -rf .theos/ 2>/dev/null || true
    rm -rf .swiftpm/ 2>/dev/null || true
else
    echo -e "${GREEN}推送 ${HAS_DEB} 个 deb:${NC}"
    for f in *.deb; do
        size=$(du -h "$f" | cut -f1)
        echo -e "  ${GREEN}• $(basename "$f")${NC} (${size})"
    done
fi
echo ""

cd "$REPO_DIR"

# ── Git 提交 ──
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard -- debs/)" ]; then
    echo -e "${YELLOW}没有新的变更需要提交${NC}"
    exit 0
fi

COMMIT_MSG=""
if [ -n "$HAS_THEOS" ]; then
    COMMIT_MSG="chore: 推送 $PROJ_NAME 源码（CI 编译）"
else
    DEB_NAMES=$(ls "$DEBS_DIR"/*.deb 2>/dev/null | xargs -I{} basename {} | tr '\n' ', ' | sed 's/, $//')
    COMMIT_MSG="chore: 推送 deb - ${DEB_NAMES}"
fi

echo -e "${YELLOW}提交信息: $COMMIT_MSG${NC}"
echo ""

git add -A debs/
git commit -m "$COMMIT_MSG
Co-Authored-By: Claude <noreply@anthropic.com>"

# ── 推送 ──
echo ""
echo -e "${YELLOW}正在推送到 GitHub...${NC}"
if git push 2>&1; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  推送成功！GitHub Actions 将自动编译${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "  查看构建状态:"
    echo -e "  ${CYAN}https://github.com/Huayuarc/shuangye.github.io/actions${NC}"
else
    echo ""
    echo -e "${RED}推送失败${NC}"
    exit 1
fi
