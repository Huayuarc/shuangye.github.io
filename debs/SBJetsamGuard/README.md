# SBJetsamGuard 1.0.0

SpringBoard Jetsam 进程内存限额缓解组件，DEB 安装后由 root launchd 服务运行，另含设置面板。不是日志/日记插件；后台无弹窗或持久日志，无 SpringBoard 注入和 UI Hook。面板操作确认弹窗仅响应手动按钮。

## 设置面板与脚本整合

设置 → SBJetsamGuard：Jetsam开关、限额策略（自适应/1024/1536/2048 MiB）、服务状态、手动应用缓存清理、默认关闭的高级 sysctl 组选项。

`startup.sh` 原文件保留在 `resources/startup.original.sh`，仅作输入参考，未安装为自动执行脚本。整合六个 sysctl 请求（线程2048、vnodes20000、两类idle1、压力终止延迟一天、vm work64）：读取类型/原值、权限检查、写后读回、停用时当前值仍等于本组件写值才恢复。全部默认关闭，一天压力延迟尤其可能导致全局内存紧张及卡机。若helper被强杀，内存中的sysctl原值快照丢失；相关临时内核设置需重新启动设备恢复，避免误称所有场景均即时可回滚。

缓存仅手动执行：只处理确认未运行应用 `Library/Caches` 中超过7天的普通单链接文件；不遍历符号链接，最多1000文件/128MiB，并有目录访问预算。系统MobileAsset/uuidtext/diagnostics与真实mobile Library/Caches的广泛删除不整合。缓存释放磁盘空间，不增加物理内存。脚本末尾 `killall -HUP SpringBoard` 已去掉，优化自身不主动注销桌面。

## 实际机制

- XNU `memorystatus_control`：GET_MEMLIMIT_PROPERTIES(8)，SET_MEMLIMIT_PROPERTIES(7)，完整保留 active/inactive 属性；不清除 FATAL 标志。
- 目标：实际 `hw.memsize` 的 25%，最多 1536 MiB；低于 2048 MiB 或取值失败则退出。此数值是保守实验默认值，不是 Apple 官方推荐阈值。
- 仅将正数且低于目标的 SpringBoard active/inactive 限额提高到目标；已有更高限额（包括越狱工具的 3x 配置）保持原样。非正特殊/默认值保持原样；不反复乘倍数，不分配目标数值那么多内存。
- 通过精确可执行路径、UID=501、PID与启动时间确认进程；操作前复读限额，检测到其他管理器变更则跳过本次写入。API不具备基于启动时间的原子 compare-and-set，仍存在很短的 TOCTOU 窗口。
- 每个 SpringBoard 生命周期最多四次尝试，间隔5秒；成功、权限失败或重试耗尽后60秒检查进程，kqueue退出事件可提前唤醒。成功后不持续与其他管理器争抢限额。
- 不抬高所有应用/守护进程限额、不设置优先级、不关闭 Jetsam 全局压力回收、不拦截 SIGILL/SIGKILL、不修改 ElleKit、CPUthermal 或其他插件。
- 后台服务的标准输出/错误指向 `/dev/null`。仅手工使用 `--status` 输出当次限额供验收，不产生持续日志。

## 适用边界

这是进程限额调整，不是 swap / 压缩内存实现，不增加物理 RAM，不宣称无限内存或彻底禁止桌面重启。若全局内存吃紧，系统仍可能回收进程。若其他插件内存泄漏，提高限额可能仅延后问题，同时挤压后台应用空间。

用户四份 IPS 均是 `EXC_CRASH / SIGILL`、SIGNAL code4，没有证明为 Jetsam。23:53 PC 在 `kongzhimeihua.dylib +0x293bc`；05:30 为多任务布局 `objc_retain`，且主线程调用链有 `CopyVault`、`floatingView`。这些属于隔离复测线索，不是已证明的根因。仅调限额不会修复 UI Hook 的无效对象。

## 安装与卸载

- Dopamine/rootless：`iphoneos-arm64`；RootHide：`iphoneos-arm64e`，只安装对应的一包。
- 安装脚本启动独立服务，不自动杀死或注销 SpringBoard。建议初次安装后手工重启一次用户空间，以确保后台服务载入。
- 卸载/升级时仅停止服务，不主动下调仍在运行的 SpringBoard 限额：立即下调可能将已超过旧阈值的桌面杀死，恰好引发待缓解的现象。卸载后不再保护下一次启动；当前进程的修改在下次 SpringBoard 自然重启时失效。没有全局 plist 或内核持久补丁。

## 手工验收

Dopamine/rootless，在设备终端以 root 执行：

```sh
/var/jb/usr/libexec/sbjetsamguard --status
/var/jb/bin/launchctl print system/com.huayuarc.sbjetsamguard
```

RootHide 使用越狱环境终端中的 `/usr/libexec/sbjetsamguard --status` 与 `launchctl print system/com.huayuarc.sbjetsamguard`；物理路径由当前隐根动态解析。

验收须记录安装前后限额及服务状态，并按原来多任务手势/插件使用场景复测。如果安装前限额已高于本版目标，本版按设计不写入；这不是额外叠加 3x。只有真机读回与复测才能证明设备上生效及是否减轻现象。

## 来源与验证

ABI 与权限依据：Apple XNU 8792.61.2 `bsd/sys/kern_memorystatus.h`、`bsd/kern/kern_memorystatus.c`、`bsd/sys/proc_info.h`。

https://github.com/apple-oss-distributions/xnu/tree/xnu-8792.61.2

源码测试、真实 macOS Theos 双方案构建与 DEB 路径审计结果见交付的 manifest/audit。真机验收独立于编译与模拟测试。
