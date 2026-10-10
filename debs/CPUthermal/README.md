# CPUthermal 1.6.2-154+isolation.4

基线：已成功构建的 isolation.3 `c048063841b79930386224978156c1b9ba8a7cc5`；完整保留原 45 文件、此前 README/策略文件。CPU 核心 `Tweak.x`、`DisplayGuard.xm`及其控制中心、设置、工具和过滤器不改。参考包为 `com.doimty.promotion-1.0.14-1-rootless.deb`，只移植刷新请求触发机制，不分发其二进制、不移植浮窗功能本体。

## Hook 完整覆盖表

以下是实现目标表，不是对所有 iOS 版本安装成功的保证；缺类/selector/编码不匹配即跳过。

|类别|类/方法|行为|
|---|---|---|
|公开 link|CADisplayLink `+displayLinkWithTarget:selector:`、`setPreferredFrameRateRange:`、`setPreferredFramesPerSecond:`、`setFrameInterval:`|先原方法，保留原 target/selector；有效时 120/120/120；弱跟踪最近原请求，关闭恢复；另保留 addToRunLoop/invalidate 生命周期|
|公开动画|CAAnimation `setPreferredFrameRateRange:`|先原请求，有效时 120/120/120；弱跟踪恢复|
|控制器|UIViewController `viewWillAppear:`、`viewDidAppear:`、`presentViewController:animated:completion:`|先原方法，节流重申自持 source，completion 原样透传|
|导航|UINavigationController `pushViewController:animated:`|参数原样，事件重申|
|窗口|UIWindow `setFrame:`、`setBounds:`、`makeKeyAndVisible`、`setWindowLevel:`|几何/level 不改，局部窗口识别和短 hold|
|视图|UIView `setFrame:`、`setBounds:`|几何不改，限频事件触发|
|滚动|UIScrollView `setContentOffset:`、`setContentOffset:animated:`、`layoutSubviews`|Point/BOOL 不改，重申 source|
|属性动画|UIViewPropertyAnimator `startAnimation`、`startAnimationAfterDelay:`|delay 不改，触发 source/短 hold|
|图层|CALayer `addAnimation:forKey:`、`setBounds:`、`setPosition:`、`setTransform:`|动画对象/key及全部几何原样；仅触发重申/短 hold，不重加原动画|
|弹窗菜单|UIAlertController `viewDidAppear:`；UIMenuController `showFromRect:inView:animated:`、`showFromBarButtonItem:animated:`；UIPopoverPresentationController `viewDidAppear:`|原参数转发后重申|
|交互菜单|UIContextMenuInteraction/UIEditMenuInteraction `_presentMenuAtLocation:`|仅 runtime 编码确认为 CGPoint 时安装|
|通知 lifecycle|SBNotificationBannerDestination、NCNotificationPresentableViewController：`presentableWillAppearAsBanner:`、`presentableDidAppearAsBanner:`、`presentableWillDisappearAsBanner:withReason:`、`presentableDidDisappearAsBanner:withReason:`、`presentableWillNotAppearAsBanner:withReason:`|仅 SB；先原方法，身份和 generation 保护短 hold；reason 只接受核验过 i/I/q/Q|
|通知 view|NCNotificationShortLookView `didMoveToWindow`|仅 SB；局部识别 SBBannerWindow，无全窗口扫描|
|私有 source|CADynamicFrameRateSource `setPreferredFrameRateRange:`|只强制插件自持 SB/app source，或 banner/floating 有效短 hold；其他原样；弱保存原 range 并恢复|
|保留系统策略|SBProMotionPolicy `policyRefreshRate`/`isLimitFrameRateEnabled`/`shouldLimitFrameRate`；SBDisplayRefreshRateController `defaultRefreshRate`/`setActiveRefreshRate:`|沿用 isolation.3，严格整型/BOOL 编码校验；不伪装 capability/观测 getter|

新增两个 include，仍只有 CPUthermalRefreshRate 一个共享状态 dylib。原过滤器覆盖 UIKit、SpringBoard、UserNotificationsUIServer、SpringBoardOutofCallUI，不扩展进程范围。

## ABI 与性能护栏

- FRR 必须是 SDK `CAFrameRateRange` 三 float HFA（S0/S1/S2）；CGRect/CGPoint/BOOL/double/CATransform3D 值参数及 completion block `@?` 用精确声明。私有方法逐项比较 return、self/_cmd及每个 argument encoding，不猜未知签名。
- 所有新增 UI Hook 先原方法。后台线程纯透传；主线程只有 force、capability、屏幕亮且解锁、App active 有效时动作。几何/动画路径只读内存门控，无磁盘/plist读、capability探测、日志或异步排队；开关关闭不分配 UI 跟踪对象/缓存。
- 每调用路径 0.2 秒节流；每进程 source 重申最多 5 次/秒；窗口判断每进程最多 4 次/秒，浮窗分类关联缓存 0.25 秒；layer 向上最多 6 层，不枚举 UIApplication.windows，不按帧扫描。新增 hook 转发本身仍有成本，不能称绝对零开销。
- 原方法重入使用主线程深度保护；私有 setter 自写 guard；弱 NSMapTable不延长 App link/animation/source 生命周期。
- SB 恰好一个自持 source + 一个空 tick keepalive。App 每进程最多一个 source，不新增 App keepalive。前后台、锁屏、熄屏、关闭开关恢复原请求并释放 source/link。
- banner/floating 每 epoch 硬上限 4 秒；will/did 重复回调不续期；banner end仅当前 presentable有效，退出尾最多0.2秒；所有延时回调核验 generation，旧回调不清新 hold。新的真实事件可以启动新的 epoch；不做无限轮询。
- 自持 source reason 仅在 runtime 确认 `^I`/`r^I`（uint32_t元素）和 count i/I/q/Q 时写1；fallback仅确认过 i/I 单 reason。`^v`、未知元素宽度或其他签名跳过。不 Hook 任意系统 source reason。

## 未照搬及边界

不新增 CAContext/display-preferences（参考不存在）；不装 QuartzCore restriction/arbitration C hook（目标系统 ABI 未获证）；不伪装 UIScreen、SB maximum/effectiveMax/active 实测getter；不复制参考的栈未初始化 capability 缺陷。保留 isolation.3 原生 UIScreen capability 门控而非猜型号。参考无限浮窗续期、全窗口扫描/退出轮询以及动画前置改写改为本版有限、先原方法事件机制。浮窗字符串只用于刷新识别（floatingView./FVWindow/FVViewController/FVFrontConsole），不提供第三方浮窗本体。

## 构建及本地测试

`tests/test_contracts.py`：完整文件保留/核心 SHA、全部 selector 覆盖、ABI 正负例、source作用域、原请求恢复、生命周期、hold generation/截止及节流策略模型；并复用原 CPU/Display 单元测试。`tests/test_mode_policy.py`、`test_display_policy.py`源内相对路径可直接运行。五模块通过 Logos preprocess。CI 精确名称 `Build Theos Projects`，rootless + RootHide，arm64/arm64e；发布附 test/audit/manifest/SHA256SUMS。

## 安装与真机待验

1. 必须卸载/禁用独立 `com.doimty.promotion` 及其他同类120Hz插件，避免重复 Hook。
2. 按越狱方案选 rootless 或 RootHide，只装一个；重启用户空间，再完全结束并重启已打开 App。
3. A/B 验证开关恢复、普通滚动、键盘/菜单/弹窗、通知进出、浮窗、前后台、锁屏熄屏及恢复；同时检查崩溃、掉帧、耗电和发热。
4. 本地策略/编译/DEB 审计不等于真机测试。刷新请求不保证面板 Hz、实际渲染 FPS、游戏上限或无掉帧；无绝对性能保证。

---
# isolation.5：温控去重、通知ABI与亮屏全局120请求

发行版本 `1.6.2-154+isolation.5`；基线成功源码提交 `112b22c5ee2691197c21a2585c884c4d5ca978bc`。保留 isolation.4 的 UI/CAAnimation/CALayer、滚动/菜单/窗口/页面/通知 Hook，SB 单一自持 source + 单一 keepalive，App 每进程最多一个自持 source、没有 App keepalive，原方法参数/ABI/递归 guard、低功耗仅 CPU 预算、背光防护、充电和 CC。`DisplayGuard.xm` 保持原文件哈希。

## 温控控制链与证据边界

核心 `CPUthermal.plist` 只注入 `thermalmonitord`：已有 CommonProduct 配置/热通知校正 → ThermalControl/ComponentControl CPU 决策及 CPMS 预算 → ApplePPM CPU Level/updateCPU → 已知热限速 IOKit 写键过滤；IOConnect 方法和系统频率读取均透传。没有获取目标设备 PMGR 固件直接写接口或验证全部私有 selector 的证据，不加盲目 hook/频率伪造/全树缩放；不能保证任意硬件紧急降频都被用户态阻止。解除温控可能带来过热、电池寿命及设备安全风险；遇到温度警告停止压力测试并冷却。`CPUthermalForceNominalCombined` 修改的是通知，不是测得 CPU 频率或 die 温。卸载或禁用后需要验证原生保护恢复。

确定修复：PrefHook `notify_register_dispatch(name,token,queue,handler)` 四参真实 ABI 完整转发，成功时记录 token、`notify_cancel` 成功后清除避免复用；低功耗/关闭状态热通知不被 full 校正；两个高频温度回调使用同一个 1 秒 nominal 节流；去掉 full 模式每 5 秒 CommonProduct 模拟热档重写；0.5 秒唤醒事务合并双通知，同一 tracked controller 每轮一次 updateCPU、随后重设最终预算；恢复标志保持 thread-local 且嵌套恢复回退既有状态。保留已有六轮短脉冲（只在明确 full 恢复事件，需真机 A/B 决定是否减量），不臆断其造成 CallAssist 卡顿。PrefHook 电池类扫描限相关 bundle/Settings/SpringBoard。源码的热写过滤仍存在宽词匹配，未获得目标设备 IOReg 调用栈/键值时不扩大其范围；固件层热保护不在保证范围。

## 全局120请求可验证范围

公开 CADisplayLink/CAAnimation + UI 路径的原请求由原 API 写入后再覆盖；动态 CADynamicFrameRateSource 仅完整 runtime ABI 验证后自持 SB/App source 的 reason + 120/120/120 范围，策略控制器整型签名确认后才 hook。SB 亮屏且设备公开 maximumFramesPerSecond≥120 时锁屏/已解锁均发请求，仅 SB 保活；App 仅自身前台、屏幕亮、已解锁时请求，后台/熄屏不强求；开关关闭或离开条件恢复最近明确的原请求。UI 事件 0.2 秒内节流、已写相同自持 source 不重复写；同一主线程轮次生命周期通知合并；私有 target/selector 已检查结果缓存，晚加载类可重试。缺类/能力/编码则保守跳过。**提交120只是调度请求，不代表面板实际120Hz、应用渲染120FPS、所有游戏取消限帧或必然无卡顿**；不 hook UIScreen maximum/active observed getter、不加 CAContext/未知 Quartz C 符号、不强改全部系统 CADynamic source。

## 事发同刻采集与真机A/B

在手机终端 `sh scripts/capture-runtime.sh /var/mobile/cputhermal-event.txt`，发生 CallAssist 短暂“未知”的**当刻**再次执行，并记录 CallAssist 界面显示/时间、同刻日志/采样返回码；脚本只读 `ps`、sysctl 存在键、限量 IORegistry 节点、设置中明列非敏感项、时间戳；输出文件由用户指定。`hw.cpufrequency` 通常是标称值，`hw.cpufrequency_max` 不保证存在，也都不是逐核即时频率；“未知”可能仅是采样窗口失败。此 tweak 不 hook sysctl/IORegistry 的读取，单纯 App 切换也没有直接触发 thermalmonitord 重申的 Hook/通知；未知和一秒掉帧均尚**未证实由 CPUthermal 造成或已彻底解决**。建议固定温度/亮度/负载下 A/B：有无 PrefHook、前后台切换、真实唤醒、模式切换，比较独立只读采样、应用原始错误码、thermalmonitord PID 和帧间隔；不得主动危险升温或通过停用硬件安全保护验证。

安装前卸载/禁用独立 `com.doimty.promotion` 和类似插件；只选对应越狱环境一个 DEB，安装后重启用户空间，再完全退出并重启 CallAssist。跑 `python3 -m unittest discover -s tests -v` 与 CI 的 Clang Werror；本地测试/CI 不等于真机。RootHide 偏好路径继续沿用共享 `CPUthermalPaths.h` 动态 `.jbroot-*` 解析，脚本/包路径须以产物逐项核验。

### 页面完全卡住的排障边界

本版把 `CPUthermalUIEvent` 的 `gUIBusy`、所有 source/公开 link 的 `state.depth`、自持 source 的 `gSBSourceWrite` 置于 `@finally`，避免窗口类 getter 或原 IMP 抛 Objective-C 异常后永久停用该进程的刷新重申；没有吞掉原异常，也不主张它一定是页面卡住的原因。页面退后台再进入偶然恢复可以是应用自身锁/动画/网络，不是掉帧或温度的证明。A/B 可仅关闭“强制120Hz”而保持温控设置不变，记录是否仍冻结；提供出问题 App/具体页面/进入时间与时区、触摸是否有震动或其他反馈、退出重入是否恢复、同刻进程 PID 和 crash/watchdog 日志，才可以继续归因。主线程 setter 保持先原参数/原方法再节流事件，原动画/几何不替换。
