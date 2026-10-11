#!/bin/bash
echo "Startup!"
echo "Tweak by LF"
echo "Version 2.3.3"
echo " 更新日志：修复RootHide，加入了少量功能"
echo " Coolapk@ColdWindy冷风"
echo "    byg.iosios.net"
echo " "
echo "    正在为你干活！"
echo "========内存清理========"
echo " "
echo " "
RED='\033[38;5;196m'
NC='\033[0m' 
echo "清理应用程序缓存中，请稍候..."

total_freed_space=0

calculate_size() {
  du -sk "$1" 2>/dev/null | cut -f1
}

free_space() {
  local dir_size
  dir_size=$(calculate_size "$1")
  rm -rf "$1"/*
  new_size=$(calculate_size "$1")
  freed_space=$((dir_size - new_size))
  total_freed_space=$((total_freed_space + freed_space))
  echo -e "正在清理 $1 ，已清理 ${RED}$((freed_space / 1024))MB${NC}"
}

# 检测 RootHide / Rootless 环境
if [ -d "/var/jb" ]; then
    JB_PREFIX="/var/jb"
else
    JB_PREFIX=""
fi

# 进入缓存目录
CACHE_PARENT_DIR="${JB_PREFIX}/var/mobile/Containers/Data/Application"
if [ -d "$CACHE_PARENT_DIR" ]; then
    cd "$CACHE_PARENT_DIR" || exit 1
    for cache_dir in *; do
        [ "$cache_dir" = "." ] || [ "$cache_dir" = ".." ] && continue
        full_cache_dir="$CACHE_PARENT_DIR/$cache_dir/Library/Caches"
        [ -d "$full_cache_dir" ] && free_space "$full_cache_dir"
    done
else
    echo "错误：找不到缓存目录 $CACHE_PARENT_DIR"
fi

directories=(
    "${JB_PREFIX}/var/MobileAsset/AssetsV2"
    "${JB_PREFIX}/var/db/uuidtext"
    "${JB_PREFIX}/var/db/diagnostics/Persist"
    "${JB_PREFIX}/var/db/diagnostics/Signpost"
    "${JB_PREFIX}/var/db/diagnostics/Special"
    "${JB_PREFIX}/var/mobile/Library/Caches"
)

for directory in "${directories[@]}"; do
    if [ -d "$directory" ]; then
        free_space "$directory"
    else
        echo "目录不存在: $directory"
    fi
done

echo "应用程序缓存清理完成。"
echo -e "总共释放空间: ${RED}$((total_freed_space / 1024))MB${NC}"
echo " "
echo " "
echo "-----------优化系统-----------"
echo " "
echo " "
set -e

# 线程参数
echo "当前线程数量"
"${JB_PREFIX}/usr/sbin/sysctl" kern.wq_max_threads=2048

# 虚拟内存参数
echo "设置虚拟节点最大值"
"${JB_PREFIX}/usr/sbin/sysctl" kern.maxvnodes=20000

# 后台管理参数
 echo "调整后台保留策略"
"${JB_PREFIX}/usr/sbin/sysctl" kern.memorystatus_sysprocs_idle_delay_time=1
"${JB_PREFIX}/usr/sbin/sysctl" kern.memorystatus_apps_idle_delay_time=1

 echo "调整后台队列限制"
"${JB_PREFIX}/usr/sbin/sysctl" kern.vm_max_delayed_work_limit=64

 echo "优化完成"
# pressureDelayTune removed; no SpringBoard HUP is performed
