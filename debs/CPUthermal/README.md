# CPUthermal 1.6.2-154+isolation.2

## 刷新率修复
- 只使用公开 CADisplayLink API，请求范围固定为 minimum=120、maximum=120、preferred=120，删除旧版 10–120 回落请求。
- 删除 UIScreen.maximumFramesPerSecond 伪装 hook，以及 CADisplay/CAContext/动态范围组等全部未验证私有 hooks（不存在未知 struct ABI、父子 hook 重叠）。设备能力取未被本模块改写的真实主屏幕 maximumFramesPerSecond。正向缓存；负向每个前台/设置事件周期最多重试四次，屏幕对象改变清缓存。没有定时重试。
- 不创建额外 CADisplayLink，不创建两秒 NSTimer；不替换应用 target/selector、不增加逐帧磁盘写入。弱引用记录真实 link，在创建、加入 run loop、应用 setter、设置变更及前后台事件时工作，后台/失活恢复应用配置，不创建熄屏刷新任务。
- 保存应用最后一次显式设置的 range / preferredFramesPerSecond / frameInterval；最后调用的 API 优先，关闭只用对应 API 恢复。嵌套 setter 用每条 link 的递归深度 guard，内部跨 API 调用不会污染原始配置。
- 仅主线程 link 参与管理；非主线程调用原样通过。首次看到已存在 link 时以其当时 range 作初始快照，无法追溯注入前曾使用哪个 setter。安装后必须重启已打开的 App/用户空间，才可完整跟踪新 dylib 下的 link。
- 保留强制 120 开关与 CC；核心 Tweak.x、DisplayGuard.xm、充电、低功耗、预期降频/亮度策略不修改。

## 不等于保证 120 FPS
实际显示 Hz 是面板扫描频率；CADisplayLink callbacks 是应用收到的更新回调频率；rendered FPS 是实际提交/呈现的新画面数量。120/120/120 是系统刷新请求，不是显示 Hz 测量，也不是渲染能力保证。系统、电源模式、应用 Info.plist 的高刷支持、温度、调度、GPU/CPU负载等仍可能限制。屏幕 getter 只报告能力，不报告实时 Hz；若原始 getter 未暴露 120，本模块保守不强制，不能仅凭设备型号伪造。

全局开关影响注入范围内前台应用的真实 display links（包括原本 30/60 的动画），可能增加回调、功耗、温升和渲染压力，甚至使重负载应用更容易掉帧。没有修改 AVPlayer、视频解码/媒体时钟或私有显示偏好，不能把 24/30/60 fps 视频变成 120 fps；视频 App 的 UI display link 仍可能受到开关影响。关闭可恢复该 App 最后显式设置，不暂停、不 invalidate 应用 link。

## 真机验证（本次未执行）
1. 选对 rootless 或 RootHide 包安装；重启已经打开的 App，必要时按越狱方式重启用户空间加载新 dylib。postinst 不自动杀死所有 App。
2. 同一页面、亮度、电源模式和温度下分别测试开关关/开，检查滑动、动画、视频播放、前后台与锁屏恢复。验证关闭后使用 range、FPS、interval 三种 API 的测试 App 恢复最后配置。
3. 本版本不额外实现 loggingEnabled 逐帧诊断；保留原设置行为，不把日志开关误称实时 Hz 测量。独立测试 App 可在它自己的真实 CADisplayLink target 中，把 timestamp 相邻差值和 targetTimestamp-timestamp 存入有界内存，停止测试后一次导出（120 回调约 8.33ms、60 回调约 16.67ms），统计分位数和长间隔。不要用额外空 link 代表被测 App，不在每帧写磁盘。
4. callbacks 的间隔只能验证回调节奏；实际 rendered FPS/卡顿需 Instruments Core Animation/Metal System Trace 和呈现记录；真实面板 Hz 需合适显示遥测或高帧率外部拍摄交叉验证。不能用 maximumFramesPerSecond getter 或 FPS overlay 单独断言实时 Hz。

## 交付和边界
提供 rootless iphoneos-arm64 / RootHide iphoneos-arm64e 两个包，干净完整 Source.zip、changes.patch、manifest.json 和 SHA256SUMS。源码 contracts、纯策略测试及本地全部模块 Logos 预处理不替代 macOS 编译和真机测试。不存在“彻底不掉帧”承诺。
