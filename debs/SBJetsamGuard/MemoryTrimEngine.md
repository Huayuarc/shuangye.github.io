# MemoryTrimEngine

`MemoryTrimEngine` 是一个只作用于**当前 helper 进程**的同步、有限时内存压力引擎。它不枚举、不终止、不启动其他进程，不写系统级 sysctl，也不调用 memorystatus。所有成功分配的块都会在函数返回前释放。

## API

```objc
#import "MemoryTrimEngine.h"
NSDictionary<NSString *, id> *result = SJGRunMemoryTrim(@"normal");
```

仅接受 `normal` 和 `deep`（不区分大小写）。调用在当前线程同步完成。进程内使用非等待信号量作为单实例锁：已有任务运行时，新调用立即返回 `stopReason = busy`，不会排队阻塞。

> 集成时需要将 `MemoryTrimEngine.m` 加入应用/工具目标。此次实现按要求未修改 Makefile、main.m、Prefs、SJGSettings 或 ScriptFeatures。

## 策略

纯预算逻辑位于 `MemoryTrimPolicy.h`，运行时与无分配 C 测试共用同一实现。

| 参数 | normal | deep |
|---|---:|---:|
| RAM 比例硬上限 | 8% | 15% |
| 初始 available 比例硬上限 | 20% | 35% |
| 绝对硬上限 | 384 MiB | 768 MiB |
| chunk | 7 MiB | 3 MiB |
| deadline | 8 秒 | 20 秒 |
| 达到计划量后的 hold | 0.15 秒 | 0.5 秒 |

每种模式的预算为对应三个硬上限的最小值，并进一步受可用内存保留量约束：

```text
reserve = max(512 MiB, physical RAM / 8)
budget  = min(RAM 比例, available 比例, 绝对上限, available - reserve)
planned = floor(budget / chunk) * chunk
```

分配每个 chunk 前后重新读取 `os_proc_available_memory`（符号不存在时使用 `host_statistics64` 的 free + inactive 快照作为兼容回退），若无法继续保留 reserve，立即停止。内存按 VM 页大小逐页写入，确保页面实际驻留；触页过程中每 64 页检查一次当前线程取消状态。计时使用单调 `systemUptime`。

## 指标来源

- `sysctlbyname("hw.memsize")`：只读物理 RAM；没有全局 sysctl 写入。
- `host_statistics64(mach_host_self(), HOST_VM_INFO64, ...)`：主机 VM 快照及兼容回退。
- `task_info(mach_task_self(), MACH_TASK_BASIC_INFO, ...)`：当前任务 resident。
- `task_info(..., TASK_VM_INFO, ...)`：当前任务 physical footprint；旧 SDK 无该 flavor 时回退为 resident。
- `os_proc_available_memory`：通过 `dlsym` 兼容解析，读取当前系统可分配内存。

## 返回值

返回字典始终包含：

- `mode`：规范化后的 `normal` / `deep`；非法输入为 `invalid`。
- `completed`：是否完整达到计划分配量并完成 hold。
- `stopReason`：`completed`、`busy`、`invalid_mode`、`low_available`、`allocation_failed`、`metrics_failed`、`final_metrics_failed`、`cancelled` 或 `deadline`。
- `peakBytes`：本次同时持有的引擎分配峰值。
- `allocatedBytes`：本次成功分配并触摸的 chunk 总字节数；当前实现不循环复用，因此与峰值相同。
- `rounds`：成功创建的 chunk 数。
- `elapsedSeconds`：同步调用经过的单调秒数。
- `initial` / `final`：各含 `physicalBytes`、`residentBytes`、`footprintBytes`、`availableBytes`。
- 同时提供扁平键：`initialPhysical`、`initialResident`、`initialFootprint`、`initialAvailable`、`finalPhysical`、`finalResident`、`finalFootprint`、`finalAvailable`；另提供相同值且带 `Bytes` 后缀的显式单位别名。
- `minimumAvailable`：本次 reserve；若在取得初始指标前失败则为 0。
- `releaseAll`：恒为 `YES`，表示退出路径释放全部引擎分配。
- `engineRevision`：当前为 `memory-trim-v1`。

`completed = NO` 不表示泄漏。低 available、指标读取失败、malloc 失败、deadline、线程取消以及正常完成均汇聚到同一释放路径。若最终指标读取失败，final 字段为零；若此前已完整完成，状态改为 `final_metrics_failed`。

## 安全边界

- 只向当前进程 `malloc`，只查询当前 task 与主机统计。
- 不调用 `kill`、`posix_spawn`、`memorystatus_control`，不发送信号。
- 不写任何 sysctl，不调整其他进程 limit，不清理其他进程文件。
- 不接受外部异步 completion block；调用方可在可取消的 `NSThread` 上运行并通过线程取消请求提前结束。
- 单实例锁只覆盖当前进程；它的目的在于防止同一 helper 内并发压力叠加。

## 测试

`tests/memory_trim_policy_test.c` 只包含预算、常量、边界和硬上限断言，不链接 Foundation/Mach，也不会执行任何内存压力分配：

```sh
BUILD=$(mktemp -d)
clang -std=c11 -O2 -Wall -Wextra -Werror \
  tests/memory_trim_policy_test.c -o "$BUILD/memory_trim_policy_test"
"$BUILD/memory_trim_policy_test"
rm -rf "$BUILD"
```

该测试覆盖两种模式的常量、8/16 GiB 示例、reserve 临界点、chunk 向下取整、零值/整数边界，以及 RAM/available 矩阵中预算不超过全部硬上限与 reserve headroom。
