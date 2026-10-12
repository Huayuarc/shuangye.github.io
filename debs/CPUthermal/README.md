# CPUthermal 1.6.2-154+isolation.15

## 电流防降频（isolation.9 唯一新功能）

依据电池充放电流阻止“因电流原因触发”的降频：电池内阻随健康度上升后，大电流放电会造成电压下垂，触发的降频与温度无关，本次只处理这一类。

- **面板**：设置 → CPUthermal 新增分组「电流防降频」，`currentGuardEnabled` 默认 **开启**（**isolation.15 起改为默认关闭，由用户开启并持久保持**）。关闭后立即恢复原值并清记录。
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

原独立显示模块（除 thermalmonitord 外还注入显示/外壳进程）在本版**彻底移除**，其职责并入 CPUthermal 核心（**仅注入 thermalmonitord**）。包内 tweak 由四个减为三个：CPUthermal、PrefHook 模块与锁屏模块；其中 PrefHook 模块已于 isolation.11 移除：部件/维修记录屏蔽不再保留，高温警告抑制迁入新的独立模块（见该节）。

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

**真机待验**：控制中心编辑页应只显示一个 1×1 的 CPUthermal 模块（不再出现第二个 1×1 模块）；其余功能表现与 isolation.9 一致。

## 模块移除与面板精简（isolation.11）

本版只做三件事：删除旧设置侧模块（PrefHook）并同步精简面板、把其高温警告抑制职责迁入新的独立模块、把保留的控制中心模块显示名改为「CPUthermal」；其余功能与 isolation.10 一致。

- **旧模块移除**：删除其 tweak 源文件与过滤器 plist；Makefile 中把它的五行变量块（`_FILES` / `_CFLAGS` / `_LDFLAGS` / `_FRAMEWORKS` / `_LIBRARIES`）与 roothide 段内对应的 `_LDFLAGS` 行删除。全仓库不再有任何字面引用（契约测试做全仓库字面扫描，预期 0 命中）。
- **部件/维修记录屏蔽已移除**：原面板开关（键、标签与页脚说明）从设置面板删除，设置首页及「通用 → 关于本机」中的部件与服务历史不再被隐藏；**设置 App（`com.apple.Preferences`）不再被任何模块注入**。
- **高温警告抑制保留于新独立模块 `CPUthermalThermalWarn`**（源文件 `Tweak_ThermalWarn.xm`、过滤器 `CPUthermalThermalWarn.plist`，**仅注入 SpringBoard**）：自旧模块迁出“热状态伪装”子集——`_OSThermalNotificationCurrentLevel`、thermal 通知状态读取与 `NSProcessInfo.thermalState` 一律伪装为正常（nominal / 0），使 SpringBoard 的高温“需要冷却”界面与自动锁屏不再出现。**新增面板开关 `blockThermalPopup`（isolation.11 起默认开启；isolation.15 起改为默认关闭、由用户开启，开启后即时生效）**：设置面板「高温警告」分组下的「屏蔽高温温度计警告」，偏好缺失时默认 NO（isolation.15 起；此前为 YES），面板任意写入后经 `com.huayuarc.cputhermal/settingsChanged` 通知即时重载，关闭即恢复系统原生高温提示/自动锁屏。isolation.5 修复的 4 参 `notify_register_dispatch` 转发、thermal token 记录与 `notify_cancel` 清理原样保留；`%ctor` 先重载偏好再安装伪装钩子。
- **注入范围**：`TWEAK_NAME` = `CPUthermal CPUthermalFaceDownLock CPUthermalThermalWarn`。CPUthermal 核心仍仅注入 thermalmonitord；锁屏模块与新的高温警告抑制模块仅注入 SpringBoard。
- **控制中心显示名**：保留模块 `Info.plist` 的 `CFBundleDisplayName` 与 `CFBundleName` 改为恰好「CPUthermal」（去掉冗余的 2x1 后缀）；尺寸声明维持四处 1×1，标识符、主类、图标与运行时尺寸开关均不动。
- **载荷计数不变**：三个 tweak（核心 + 锁屏 + 高温警告抑制）、每包 7 个 Mach-O、8 个 plist（3 个过滤器 + LaunchDaemon + entry + Settings 的 Info/Root + 控制中心 1 个 Info.plist）。

**真机待验**：设置面板不再出现部件/维修记录分组与开关且无孤立分组；设置面板新增「高温警告」分组与「屏蔽高温温度计警告」开关（isolation.15 起默认关闭、由用户开启，改动即时生效）；设置首页与「通用 → 关于本机」恢复系统原生记录；开关开启时高温警告界面与自动锁屏被抑制、关闭后恢复系统原生行为；控制中心模块显示名为「CPUthermal」；其余表现与 isolation.10 一致。

## 设置面板动态 specifier 重构（isolation.13）

本版删除 `Settings/Root.plist`，把原有 19 个面板项目（8 个分组、9 个偏好项、2 个操作按钮）的 label、footer、key、default、validTitles、validValues 与 action 全部内置到真实 `PSListController` 子类 `CPUthermalSettings`（`FRootListController`）的 `-specifiers` 中，并用 `_specifiers` 缓存；PreferenceLoader 入口、bundle 元数据和图标保持不变。其余运行功能与 isolation.11 完全一致。

此前运行模块对 `blockThermalPopup` 等缺失键按 YES 处理，但设置面板读取函数忽略 specifier 的 `default`，把未单独硬编码的缺失键显示成关闭；这是显示错误，运行态并未关闭。现在读取顺序统一为：prefs 中的显式值优先（包括显式 false），键缺失时读取动态 specifier 的 `default`，specifier 也无默认时才返回 false；默认值仅用于显示，不主动落盘。因此 `blockThermalPopup`、`currentGuardEnabled`、`smartChargeUseSmartBatteryAPI` 默认显示开启（**isolation.15 起三者默认显示关闭，与其他开关一致**），`powerMode` 默认 `fullPower`，`smartChargeStopLevel` 默认 80，其余开关默认关闭；用户手动关闭后离开并重进页面仍显示关闭。

**真机待验**：设置页可正常进入且完整显示全部 19 项；首次安装或清除对应偏好键后全部开关显示关闭（isolation.15 起）、运行方式显示解除温控、停充阈值显示 80%；手动关闭后退出并重进仍保持关闭；点击选项能写入并发出即时通知，重启用户空间与开源按钮可正常执行；重启设置 App 后状态保持。

## 动态分段行空白修复（isolation.14）

真机（iPhone 14,2 / iOS 16.1.2）确认：isolation.13 的动态面板中「运行方式」与「停充电量」两个分段（PSSegmentCell）渲染为空白，其余开关与按钮正常。

**根因**：由 plist 加载器在运行时创建的分段 specifier，其「值/标题」状态由 `-[PSSpecifier setValues:titles:]` 填充，分段控件据此布局；isolation.13 的面板完全由代码构造 specifier，只设置了 `validTitles`/`validValues` 属性而从未调用该私有方法，分段控件取不到任何分段，整行因而渲染为空白。

**修复**（最小改动，双保险，其余一切不变）：

- 新增 `PSSpecifier (CPUthermalSegmentValues)` 分类声明（只声明不实现，调用带 `respondsToSelector:` 守卫），并新增 `CPUthermalApplySegmentValues()` 为两个分段补齐状态：运行方式 `lowPower`/`fullPower`（标题 `低功耗`/`解除温控`），停充电量 `70`–`100`（标题 `70%`–`100%`）；`validTitles`/`validValues` 属性保留。
- 新增 `CPUthermalCellType()`：两个分段与两个按钮的 cell 类型改为运行时经 `+[PSTableCell cellTypeFromString:]` 解析，解析失败或返回 0 时回退编译期常量 `PSSegmentCell`/`PSButtonCell`；七个开关仍使用 `PSSwitchCell` 常量（真机已验证渲染正常，不改动）。
- 面板顺序、label、footer、default、action、读写与通知逻辑、Root.plist 移除状态全部不变。

**真机待验（isolation.14）**：「运行方式」显示为低功耗/解除温控两段且当前选中解除温控；「停充电量」显示 70%–100% 七段且当前选中 80%；其余开关与按钮显示与行为不变；两处不再空白。

## 偏好持久化加固与开关默认关闭（isolation.15）

真机（iPhone 14,2 / iOS 16.1.2）录屏证据：在 CPUthermal 面板开启「锁定阳光暴晒模式」「智能停充」「停充时自动禁流」等默认关闭项后，面板内即时显示开启；退出到设置主页再重进，这些开关全部回到关闭。此前的三个"静默默认开启"项（`blockThermalPopup` / `currentGuardEnabled` / `smartChargeUseSmartBatteryAPI`）虽仍显示开启，但不代表已成功保存。用户要求：① 修复持久化（开关写入必须存得住）；② 所有开关改为"首次默认关闭、由用户开启后持续保持"。

**根因（Filza 现场定案，Dopamine rootless）**：`/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist` 属主为 **root:wheel 且权限不含移动用户（mobile 不可读）**，内容只有 `{powerMode=fullPower, smartChargeDisableInflow=YES}` —— 即：

- **属性主循环**：模块（root）写入偏好后文件属主变为 root、权限受限 → **设置面板进程（mobile）读不到** → 面板打开时 `-prefs` 拿到的是空字典 → 写入时以"空字典 + 当前这一个键"整文件覆盖 → **每开一个开关就抹掉其它键**；
- **核心自愈叠加**：核心 `loadPrefs` 的 `powerMode` 自愈（root 写）又把文件重写成 root 属主 → 循环，文件最终只剩最后写入的一个键 + `powerMode`。
- 次要缺陷（已一并加固）：旧版 `CPUthermalCurrentPrefPath()` 在 rootless 下仍做 `jbroot()`/`/var/jb` 探测（落点可能漂移）；"清理旧副本"用字符串比较，同名别名（同一 inode）会被误删；`writeToFile:atomically:` 返回 YES 不代表可读回，写后无校验。

**修复（`include/CPUthermalPaths.h` 加固，其余功能不动）**：

- **路径数据锚定**：`.jbroot-*` 根评分改为数据锚定——含现有 `com.huayuarc.cputhermal.plist` 的根 **+10000**（优先于仅含 dylib 的 +1000），其后 dylib +1000、`Library/MobileSubstrate` +100、`usr/lib` +10，同分再按 mtime 最新；保证同一份数据在所有进程稳定解析到同一个根。Rootless 分支**直接返回真实 var 路径** `kCPUthermalPrefRootFSPathC`，不再做 `jbroot()`/`/var/jb` 探测。
- **同文件保护**：新增 `CPUthermalSameFile()`（stat 的 `st_dev`+`st_ino` 比较，两文件都存在才可能为"同一文件"）。所有 `removeItemAtPath:` 调用点（读两处、写一处）先过闸门 `CPUthermalPrefDeletionAllowed()`：**非同一文件 AND 仅 RootHide 模式（当前路径含 `/Containers/Shared/AppGroup/.jbroot-`）**；**rootless 一律不执行任何删除**。
- **Legacy 迁移**：候选列表补充 jbroot 转换变体（`/var/jb/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist` 及其 symlink 解析变体）与原有三类（各 `.jbroot-*`、解析后的旧 JB `Library/Preferences` 路径、真实 var 路径），去重；仅用于"读取迁移"，迁移时读取+写入规范路径，rootless 不删除旧件。
- **属主/权限修复（本次根因修复）**：新增 `CPUthermalFixPrefOwnership(path)`——对存在的文件执行 `chown(path, 501, 501)`（mobile:mobile）+ `chmod(path, 0644)`，best-effort、失败静默；在 `CPUthermalWritePrefs()` **成功写出后**调用（面板、核心自愈、ChargeTool 等所有写者自动覆盖），迁移写入路径同样调用；核心 `%ctor` 启动时对 `CPUthermalCurrentPrefPath()` 补一次；`scripts/postinst.in` 的 `configure` 分支对已存在的旧文件执行 `chown mobile:mobile` + `chmod 644`（打包时经 Makefile 渲染进 `layout/DEBIAN/postinst`）。这样 mobile 进程恢复可读写同一文件，面板不再以空字典覆盖、模块自愈也不再破坏属主。
- **写后校验 + 重试 + 回退**：`CPUthermalWritePrefs()` 写入后立即 `dictionaryWithContentsOfFile:` 读回并与入参 `isEqualToDictionary` 全等比较；失败重试一次；仍失败回退写 `CPUthermalCanonicalPrefPath()`（RootHide=当前根；rootless=真实 var 路径）并再次校验；只有成功后才执行清理循环（并修属主）。返回准确的 ok。
- **面板级写校验**（`Settings/FRootListController.m` `setPreferenceValue:specifier:`）：写偏好后立即 `CPUthermalReadPrefs()` 读回，用 `CPUthermalPrefValueEquals()`（NSNumber 走 `isEqualToNumber`、NSString 走 `isEqualToString`）比对 `readBack[key]` 与写入值；不一致 → 再写一次并复核；仍不一致 → 直接 `CPUthermalWritePrefsAtPathVerified(prefs, CPUthermalCanonicalPrefPath())` 并复核。`notify_post(kCPUthermalSettingsChangedNotifC)` 保持在校验之后。
- **面板排查结论（读路径正常，问题在写入未持久化）**：`readPreferenceValue:` 的取值顺序（prefs 显式值优先含 false → specifier 的 `default` → NO）自 isolation.13 起即正确，未回写默认值、不触发清理；`-specifiers` 一次性缓存、7 个开关的 key/default 与读写 selector 均正常。唯一失效点在写入链路（落点漂移 + 别名误删 + 写后无校验），已由上述加固兜住。

**全部开关"首次默认关闭"（面板 + 模块一致）**：

- 面板三个开关默认值 `YES → NO`：`blockThermalPopup`、`currentGuardEnabled`、`smartChargeUseSmartBatteryAPI`（其余四个本就为 NO）；footer 文案"默认开启"改为"默认关闭（开启后生效）"。
- 模块缺省值对齐（缺失键一律 NO，随开关实时生效）：`Tweak_ThermalWarn.xm` 的 `gBlockThermalPopup = v ? [v boolValue] : NO;`；`Tweak.x` 的 `blockPopup` 由"恒开"改为读取偏好 `blockThermalPopup`（缺失=NO），经 `com.huayuarc.cputhermal/settingsChanged` 即时重载；`Tools/CPUthermalChargeTool.m` 的 `currentGuardEnabled`、`smartChargeUseSmartBatteryAPI` 回退值由 YES 改为 NO。
- 其余开关读取点核对：`lockWhenFaceDown`（FaceDownLock.xm，nil→NO，通知重载）、`smartChargeEnabled` / `smartChargeDisableInflow`（ChargeTool，NO）、`sunlightLockedEnabled`（面板写入，运行时消费方在当前树中不存在，属既有设计，未改）；segments 默认值保持 `powerMode=fullPower` / `smartChargeStopLevel=80`。

**真机验证步骤（Dopamine rootless）**：① 安装 rootless DEB（`iphoneos-arm64`），重启用户空间（`launchctl reboot userspace` 或包内按钮）；② 用 Filza 查看 `/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist`——属主应为 **mobile:mobile**、权限 **644**（postinst 与写路径都会修复）；③ 进入设置 → CPUthermal，确认 **全部开关首次显示关闭**（含「屏蔽高温温度计警告」「启用电流防降频」「使用 SmartBatteryAPI」）；④ 逐个开启「锁定阳光暴晒模式」「智能停充」「停充时自动禁流」等，返回设置主页再重进，确认**保持开启**；再关闭任一开关，重进确认**保持关闭**；⑤ 用 Filza/`plutil -p` 查看该文件内容：应 **同时包含多个键值**（不再只剩单个键 + powerMode），且属主仍为 mobile:mobile。

## 保持不变

FaceDownLock、充电守护原有智能停充逻辑、路径解析、频率读取、原维护脚本模板不改；Makefile 除按前述小节删除旧设置侧模块引用与新增高温警告抑制模块外不改。控制中心保留模块尺寸维持 1×1，显示名改为「CPUthermal」，其源码、图标与标识符不动，其余控制中心行为与 isolation.10 相同。核心 tweaks 为 CPUthermal、锁屏模块（FaceDownLock）与高温警告抑制模块（CPUthermalThermalWarn）三个；原独立显示模块及其 dylib/plist 已删除，旧设置侧模块及其 dylib/plist 亦已删除（其部件屏蔽代码不再存在于任何文件），包内不再有对应载荷。isolation.6 已删除的刷新率强制功能和诊断文件日志不重引入。硬件/固件紧急保护不修改。

## 风险与验证

更高预算请求与更高的适配器输入电流上限可能明显增加发热与耗电。电池电压下垂、电流/功率限制和硬件保护可能反而降低性能；不能保证持续最大时钟、帧率或实际满功率。保护仍可接管，请勿通过危险升温验证。

电流防降频的诚实边界：**无法消除全部电流相关降频**（硬件/固件保护、电压下垂、温度与电量状态仍可独立触发降频）；**无法提升电池本身的放电能力**（只抬高适配器输入电流上限与重申用户态预算，不改变电芯内阻与电压下垂）；**可能增加发热**（更高输入电流与更高预算会提高发热）；以上阈值均为源码假定，**真机未验证**。

选择对应环境的一个 DEB：Rootless 或 RootHide。安装/升级脚本重启 thermalmonitord 并重新加载充电守护；安装后手动重启用户空间，使其他已运行进程重新载入插件。

本地 `python3 -m unittest discover -s tests -v` 是静态合同、ABI 宏编译与模式模型验证，不是真机运行验证。用户截图里的新 CPU/GPU/Package 值、接口支持情况、预算是否被采纳、full→low→full→disable 和卸载恢复，都需要真机验证；不能把请求值或截图数值当成整个 SoC 已满功率的证明。
