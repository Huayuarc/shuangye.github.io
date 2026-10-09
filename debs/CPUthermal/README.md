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
