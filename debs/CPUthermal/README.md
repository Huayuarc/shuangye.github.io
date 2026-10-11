# CPUthermal 1.6.2-154+isolation.10

## 电流防降频（isolation.9 唯一新功能）

依据电池充放电流阻止“因电流原因触发”的降频：电池内阻随健康度上升后，大电流放电会造成电压下垂，触发的降频与温度无关，本次只处理这一类。

- **面板**：设置 → CPUthermal 新增分组「电流防降频」，`currentGuardEnabled` 默认 **开启**。关闭后立即恢复原值并清记录。
- **采样**：`CPUthermalChargeTool` 内新增独立 **5 秒** `NSTimer`；原 15 秒智能停充节奏、语义与写入完全不改。
- **读取**：电流 `InstantAmperage` → `Amperage` 回退（mA，负值=放电）；适配器连接复用 `AdapterConnected`；限流键 `AdapterCurrentLimit` → `USBPDCurrentLimit`（读现值，**键不存在跳过该键**）。
- **充电提升（只升不降）**：适配器已连接且净电流 ≤ **-50mA** 连续 **3** 个采样（15s）→ 对存在的限流键，现值 < **3000** 时写到 **3000mA**（硬上限 3000，永不写更高值，也绝不降低现值）。首个键实际写入前把原值持久化到 prefs `__currentGuardOriginalLimits`。
- **释放**：净电流 > **-10mA** 连续 **12** 个采样（60s）、适配器断开、功能关闭、`reset` 子命令、SIGTERM/SIGINT/SIGHUP → 恢复原值并清记录。
- **放电保护**：适配器未连接且 |净电流| ≥ **2000mA** 连续 **3** 个采样 → `notify_post("com.huayuarc.cputhermal/currentStress")`，**至多每 30 秒一次**；|净电流| < **1200mA** 停止；无需恢复动作。
- **守护侧**：`Tweak.x`（thermalmonitord）在现有注册观察者处新增该通知观察，engine queue + 静态 ≥20s 节流；触发时若 `shouldApplyFullCPUProtection()` 则调用已有 `applyFullPowerToCommonProduct()` 与 `restoreFullPowerToTrackedControllers()`。**不新增定时器**，低功耗/禁用时忽略；CPU/GPU/Package floor 语义与 isolation.8 完全一致（未重新引入 120Hz、诊断文件日志、假注销防护、随使用强度自适应功率、powerd 注入）。
- **绝不触碰**：`ExternalConnected`、`PredictiveChargingInhibit`、`ChargingCurrentLimit`、`ChargeCurrentLimit` 等充电/停充键；不产生任何文件日志；除 `__currentGuardOriginalLimits` 外不写其它偏好键。

## 跨版本兼容矩阵（isolation.9）

新增共享小工具 `include/CPUthermalCompat.h`（`CPUthermalSystemMajorVersion()` 进程内缓存、`CPUthermalNumberValue()` 容忍 CFNumber 整数/浮点/布尔与 CFString、`CPUthermalPropertyNumber()` 按顺序回退键读取），被 ChargeTool 与 Tweak.x 共用。

| 目标 | iOS 15 | iOS 16 | iOS 17 | 全部缺失时 |
| --- | --- | --- | --- | --- |
| 电流 | `InstantAmperage` → `Amperage` | `InstantAmperage` → `Amperage` | `InstantAmperage` → `Amperage` | 不写不改，等待下个采样（不发通知） |
| 适配器连接 | `AdapterDetails` → `ExternalConnected`/`ExternalChargeCapable` | 同左 | 同左 | 视为未连接：不提升，按放电分支评估 |
| 限流键 | `AdapterCurrentLimit` → `USBPDCurrentLimit` | 同左 | 同左 | 无键可写 → 安全降级 no-op，不写任何键、不留脏记录 |
| 电池服务 | `AppleSmartBattery` → `IOPMPowerSource` | 同左 | 同左 | 服务为空 → 直接返回，不写不改 |

数字解析容忍 CFNumber（整数/浮点/布尔）与 CFString；CFString 仅接受“纯数字（允许首尾空白）”，带单位或其它尾随内容按不可解析处理（宁可不写，也不误写）。`CPUthermalSystemMajorVersion()` 无法解析时返回 0，调用方必须当作未知版本，不当作任意已知版本。

对现有模块只做有界审计，未广泛重构稳定代码。审计结论：全仓库无硬编码系统版本分支（只有注释提及 iOS 15/16/17，不参与逻辑）；唯一手工数字转换点在背光只抬不压路径，已确认非数字类型走 `numeric=NO` 分支、不崩溃，故**保持不变**。

## 用户态预算实验

“解除温控”名称与 `fullPower` 偏好值保持不变。在现有支持的 CPU/GPU/Package 预算路径请求 Floor=100、Ceiling=100；CPU Level=0。这里的 100 是现工程的百分比预算请求，不是 MHz、瓦数、最大时钟、实际满功率或整个 SoC 硬锁。上一版 CPU Floor=100 已由用户真机反馈证实没有硬锁 A15；本版不能据此推断 GPU/Package 已被硬件采纳。

Package 表示共享功率预算，不是独立的 SoC 全模块控制协议，不包含神经引擎、ISP、射频等模块各自的 floor。独立 SoC Floor：`not_verified/not_implemented`。已精确搜索基线、项目头文件及参考包的 selector/ObjC 分析材料，未找到可验证的独立 SoC floor setter 或真实 IOKit 键，更没有其百分比单位、owner/source、返回 ABI 的证据。因此不猜测 `setSoCPowerFloor:`、不改名冒充，不增加未知 IOConnect 调用或寄存器写入。继续实现需对应设备系统 thermalmonitord/framework 的接口与调用材料、完整方法编码、百分比单位及 source 语义证据。

## 模式与恢复

- full：CPU/GPU/Package Floor/Ceiling 请求 100，CPU Level0。CommonProduct 与 MitigationController 路径均覆盖；来源沿用现工程 0..5（源码假定，共 6 个），不猜新枚举。
- low：CPU 保留 2500mW / Ceiling45% / Level2 / Floor0；主动清掉 GPU/Package 所有已有来源的 Floor100，请求 Floor0，防止 full→low 残留。清理函数不调用 full 恢复，不误回 Level0，不启用全局 PowerSave，不改变亮度。
- disabled：追踪控制器和 CommonProduct 的 CPU/GPU/Package floors 清零，原更新后再清一次，再交还原生预算。卸载仍使用原 prerm 的 thermalmonitord 重启清理运行态，不 kill powerd；卸载实际恢复效果待真机验证。
- GPU/Package floor setter hook 仅在目标方法存在、返回 `void`、隐含参数 `@`/`:`、两个显式整数参数的完整编码匹配时安装；仅接受 `i/I/q/Q` 精确组合，单个声明 owner/class/selector 去重。继承路径不重复安装；未知 ABI 保留原实现。
- 主动发送使用 `respondsToSelector` 加完整类型检查；第一个 floor 参数和第二个 source 参数都按实际 signed/unsigned 32/64 位类型发送，不把对象或指针强转整数。
- 每次原 updateGPU/updatePackage 后仅在同线程有界重申共享预算，以 thread-local guard 防递归。不新增高频 timer、每秒 setter 循环、UI observer 或跨线程 floor 测试任务。

## 防降亮度（isolation.9 并入核心）

原独立显示模块（除 thermalmonitord 外还注入显示/外壳进程）在本版**彻底移除**，其职责并入 CPUthermal 核心（**仅注入 thermalmonitord**）。包内 tweak 由四个减为三个：CPUthermal、CPUthermalPrefHook、CPUthermalFaceDownLock。

核心侧保留并强化的部分：

- **热配置 backlight 子树修补**：仍在 `_getConfigurationFor` 返回值上修 `backlightComponentControl`（`BacklightPower` 取原生最大档、`expectsCPMSSupport=NO`、`maxThermalPower/minThermalPower` 置无限制、显示缓解键清零），并把 `keyIsBacklightThermalLimit` 命中的限制键替换为学到的面板上限。
- **核心自有 IOKit 写入拦截**：`IORegistryEntrySetCFProperty` / `IOServiceSetProperty` 钩子只作用于本进程（thermalmonitord）自己的写入；`BLNitsCap`（16.16）与 `brightness-nits` 键已并入核心键集，0 值视为关机/关闭指令、绝不替换。
- **只升不降**：写入侧新增比较（`if (original + 0.5 >= candidate) return nil;`），只在原值确实低于候选上限时才替换，绝不把更高的原值压回上限。
- **恢复机制（周期 + 事件）**：20 秒周期自检（屏熄提前返回）、屏幕点亮/解锁事务（唤醒后 0.5/2.5/4.5 秒三次补做）、`full`/`low` 模式切换与热配置补丁后都会触发“只升不降”恢复；恢复前后都做面板上限学习（`CPUthermalRememberBacklightMaximum` 只采信 400–10000 nits 的合理值，并尽力从 CoreBrightness 客户端补充）。
- **低开销与无文件日志**：亮度自检只有 20 秒一个节拍，不新增 `dispatch_source` 高频定时器、不产生任何日志文件。

**诚实边界（用户明确取舍）**：核心只能事后纠正，无法拦截其它进程写入，故比被移除模块弱——原模块能在显示/外壳进程内部直接改写其出站写入，核心只能在 thermalmonitord 自己写入时与事后做“只升不降”纠正；若其它进程持续写入更低的限制值，核心只能在下一次事件/周期节拍把它抬回来。热配置子树修补仍能减少 thermalmonitord 主动要求降亮度的路径，但不能阻断 CoreBrightness/显示驱动的独立决策，也不能绕过硬件/固件保护。

## 控制中心模块精简（isolation.10）

本版唯一改动：删除第二个（1x1）控制中心模块及其资源目录，保留的 CPUthermal 控制中心模块尺寸声明改为 1×1；其余功能与 isolation.9 完全一致（温控/预算、电流防降频、跨版本适配、防降亮度核心逻辑、设置面板与两个工具均不动）。

- **删除**：第二个 CC 模块的四个源文件（`Module.h`、`Module.m`、`ModuleViewController.h`、`ModuleViewController.m`）与其资源目录（`Info.plist` + `SettingsIcon.png`）整体删除；Makefile 的 `BUNDLE_NAME` 由三项减为两项，并删除该模块自己的 `_FILES` / `_INSTALL_PATH` / `_CFLAGS` / `_FRAMEWORKS` 变量块、roothide 段对应的 `_LDFLAGS` 行，以及 `after-stage` 中创建与拷贝其 bundle 的两行。全仓库不再有任何字面引用。
- **保留模块缩为 1×1**：`ControlCenter/resources/Info.plist` 中 `CCSModuleSize` 与 `ModuleSize` 的 Landscape/Portrait 四处 `Width` 由 2 改为 1（`Height` 原本即为 1），改后四处均为 Height=1/Width=1。**其余键一字不改**：显示名与 `CFBundleName` 仍是「CPUthermal 2x1」（按用户要求不动）、标识符 `com.huayuarc.cputhermal.ccmodule`、主类 `CPUthermalCCModule`、图标 `SettingsIcon.png`、`CCSGetModuleSizeAtRuntime=false` 全部保持原样。
- **契约固化**：测试对全仓库做字面扫描，任何文件都不得再出现被移除模块名或其资源目录名；`BUNDLE_NAME` 必须恰好为 `CPUthermalSettings CPUthermalCC`，`after-stage` 只允许 stage 一个控制中心 bundle；保留模块四处 `ImageSize` 必须为 Height=1/Width=1。
- **载荷计数**：包内 tweak 仍为三个，Mach-O 由 8 个减为 7 个（三个 tweak + Settings + 保留的 CC 模块 + 两个工具），plist 由 9 个减为 8 个（其中 2 个为 Settings bundle 的 Info/Root 等，控制中心只余 1 个 Info.plist）。

**真机待验**：控制中心编辑页应只显示一个 1×1 的 CPUthermal 模块（不再出现第二个 1×1 模块），模块名仍显示为「CPUthermal 2x1」；其余功能表现与 isolation.9 一致。

## 保持不变

PrefHook、FaceDownLock、充电守护原有智能停充逻辑、路径解析、频率读取、原维护脚本模板不改；Makefile 除按上节精简控制中心模块外不改。控制中心保留模块本版只做尺寸精简（1×1），其源码、显示名、图标与标识符均不动，其余控制中心行为与 isolation.9 相同。核心 tweaks 为 CPUthermal、CPUthermalPrefHook、CPUthermalFaceDownLock；原独立显示模块及其 dylib/plist 已删除，包内不再有对应载荷。isolation.6 已删除的刷新率强制功能和诊断文件日志不重引入。硬件/固件紧急保护不修改。

## 风险与验证

更高预算请求与更高的适配器输入电流上限可能明显增加发热与耗电。电池电压下垂、电流/功率限制和硬件保护可能反而降低性能；不能保证持续最大时钟、帧率或实际满功率。保护仍可接管，请勿通过危险升温验证。

电流防降频的诚实边界：**无法消除全部电流相关降频**（硬件/固件保护、电压下垂、温度与电量状态仍可独立触发降频）；**无法提升电池本身的放电能力**（只抬高适配器输入电流上限与重申用户态预算，不改变电芯内阻与电压下垂）；**可能增加发热**（更高输入电流与更高预算会提高发热）；以上阈值均为源码假定，**真机未验证**。

选择对应环境的一个 DEB：Rootless 或 RootHide。安装/升级脚本重启 thermalmonitord 并重新加载充电守护；安装后手动重启用户空间，使其他已运行进程重新载入插件。

本地 `python3 -m unittest discover -s tests -v` 是静态合同、ABI 宏编译与模式模型验证，不是真机运行验证。用户截图里的新 CPU/GPU/Package 值、接口支持情况、预算是否被采纳、full→low→full→disable 和卸载恢复，都需要真机验证；不能把请求值或截图数值当成整个 SoC 已满功率的证明。
