# ScriptFeatures helper 模块

## API 与接线约定

```objc
void SJGApplyScriptSettings(NSDictionary *settings);
NSDictionary *SJGScriptStatus(void);
NSDictionary *SJGCleanCaches(NSDictionary *settings);
void SJGRestoreScriptSettings(void);
```

- 设置加载/刷新：调用 Apply，绝不自动清理。
- 用户明确点击“清理缓存”产生的手动通知：通知处理器读取当前设置并调用 CleanCaches，将返回值显示为 cleanup；不是启动通知、定时器或普通设置刷新。
- helper 正常停止：调用 Restore。异常退出/SIGKILL 无法保证恢复。
- 所有接口同步进入模块独立串行队列；不得从信号处理函数直接调用。
- 编译 ScriptFeatures.m，使用 C11、Objective-C blocks/ARC、Foundation；ScriptCacheCore.h 为模块私有可移植文件系统核心。没有改动 main、Policy、Makefile 或 Prefs；调用方负责接入构建/通知。

## 设置（全部默认 NO，只接受 NSNumber 布尔值）

| 设置 | sysctl | 目标值 |
| --- | --- | --- |
| experimentalSysctls | 六项总开关 | NO |
| threadTune | kern.wq_max_threads | 2048 |
| vnodeTune | kern.maxvnodes | 20000 |
| sysprocsIdleTune | kern.memorystatus_sysprocs_idle_delay_time | 1 |
| appsIdleTune | kern.memorystatus_apps_idle_delay_time | 1 |
| pressureDelayTune | kern.memorystatus_kill_on_sustained_pressure_delay_ms | 86400000 |
| vmWorkTune | kern.vm_max_delayed_work_limit | 64 |
| cleanAppCaches | 仅手动清理应用 Library/Caches | NO |

pressureDelayTune 是风险实验选项：24 小时持续内存压力延迟可能导致卡顿或不稳定，不是关闭 Jetsam 或修改 Jetsam 优先级；状态包含明确警告。没有声称这些参数提高性能。

## sysctl 行为

核对 Darwin OIDFMT 返回的 CTLTYPE_INT/QUAD，再查询/验证 4/8 字节宽度；其他类型、未知 OID、不可读、只读、权限错误均记录 state/errno，不继续盲写。原值只在首次准备写入前读取保存，重复刷新和开关循环保留该快照。成功写入后回读验证；禁用选项/总开关/正常停止时，仅当前值仍等于本模块 written 值且宽度相同时恢复原值，恢复后再次回读。已经等于目标但没有由本模块写入的值不取得恢复所有权。快照仅存在于 helper 进程内存，不存日志、不落盘。

没有写 Jetsam priority、kill-disable 或其他额外内核开关。

## 缓存安全边界

仅真实 /var/mobile/Containers/Data/Application（接受系统标准 /private/var 别名）下的直接 UUID 容器。UUID 格式与不跟随链接的 MCM metadata plist 必须有效；只访问各容器 Library/Caches。realpath 白名单及 lstat/openat/O_NOFOLLOW/fstatat/unlinkat 校验；拒绝跨设备挂载、硬链接、符号链接、特殊文件。目录可遍历但绝不删除；Documents、Preferences、容器根、其他系统目录不在删除范围。

使用 dlsym(RTLD_DEFAULT) 解析稳定 proc_listpids/proc_pidpath C ABI，不依赖公共 SDK 中缺失的 libproc.h。应用 executable 路径解析数据 UUID，并通过 .app/Info.plist 的 bundle id 与 MCMMetadataIdentifier 比对；清理每个容器前重新检查。任一存活 PID 无法检查、app bundle 无法识别、符号缺失时保守跳过。此检查是尽力而为，不能原子阻止检查后应用启动，亦不保证捕获全部非 app 后台服务打开的文件；不应当作跨进程文件锁。

删除前通过持有文件 fd 与最新目录项的 dev/inode/size/mtime/ctime/nlink 双重检查。POSIX 不提供“按 inode 比较后原子 unlink”，最后检查到 unlink 的极短竞争窗口仍存在。要求 mtime 与 ctime 都严格超过 7 天；新生成/新改动文件跳过。每次最多删除 1000 文件、128 MiB 逻辑字节；最多访问 20000 条目、深度 16，达到限制停止。returned removedBytes 是成功 unlink 的逻辑文件大小，并不承诺等量实际磁盘释放。

cleanAppCaches=NO 时立即返回 disabled/说明，未扫描应用目录。不存在自动、启动、定时或停止清理。

## 明确舍弃原脚本行为

resources/startup.original.sh 与输入字节完全相同，0644，仅审计参考，不进入 layout、不挂载自动执行、不调用 shell/spawn/system。原脚本 broad rm-rf 会删除仍在使用的应用缓存，并扩大到 MobileAsset、uuidtext、diagnostics/Persist/Signpost/Special 和全局 mobile Caches；这些删除全部移除。killall -HUP SpringBoard 也移除，避免重载系统进程。Rootless/RootHide 不将真实应用容器错误重定向为 /var/jb/var/mobile。

## 验证

已在隔离生成的 /tmp fixture 上通过：

```sh
cd /var/minis/workspace/SBJetsamGuard/source
clang -std=c11 -O2 -Wall -Wextra -Werror tests/script_cache_test.c -o /tmp/sjg-script-cache-test
/tmp/sjg-script-cache-test
cmp resources/startup.original.sh /var/minis/attachments/uploads/startup.sh
```

覆盖默认新文件不删、超过七天文件、UUID 白名单、排除容器、符号链接、Documents/Preferences、嵌套目录保留、超大文件跳过、1000 文件上限。测试宏 SJG_SCRIPT_TEST_ROOT 仅可在 SJG_SCRIPT_TESTING 测试编译中定义，生产设置不能覆盖根路径。

已读取并核对 theos/sdks iPhoneOS16.5.sdk/usr/include/sys/sysctl.h 的公开 sysctlnametomib/sysctlbyname、CTL_MAXNAME=12、CTLTYPE/INT/QUAD；公共 libproc.h 返回 404，因此使用 dlsym。CTL_SYSCTL=0/OIDFMT=4 对应 XNU sysctl SPI；若设备不支持，保守返回状态。

当前 Alpine 环境没有 Apple Foundation/SDK 编译环境；不能声称已完成 iOS 全模块编译或设备 sysctl 运行测试。CI/macOS 应运行：

```sh
xcrun --sdk iphoneos clang -std=c11 -fobjc-arc -fblocks -fsyntax-only \
  -isysroot /path/to/iPhoneOS16.5.sdk -arch arm64 \
  -miphoneos-version-min=15.0 ScriptFeatures.m
# 再由调用方既有工程 make 构建/链接验证（不修改本模块 scope 外文件）。
```
