# 隐藏通知清除按钮 1.0.5

**作者 / 维护者：L.E**

针对 iPhone 14 Pro Max / iOS 16.3 / Dopamine RootHide（隐根）的轻量通知界面插件。内部文件名与包 ID 保持不变，可直接覆盖升级，避免旧版重复加载。

## 功能

- 隐藏锁屏及通知中心中，通知分组展开后的整行「App 名 / 折叠按钮 / 清除按钮」。
- 1.0.5 补充隐藏分组底部独立出现的「折叠 / ×」控制行，连同其专属高度和边距归零，并提供局部视图零高度兜底。
- 不删除通知，不修改通知请求、通知卡片内容及 App 内部界面。
- **不隐藏通知卡片自身的 App 名、时间或内容。**
- 整行被隐藏后，不能再点这一行的折叠/清除按钮，这是本插件的预期效果；系统原有的其他通知操作不在修改范围。
- 无设置页、无开关、无后台常驻采样、无网络请求、无通知数据库读写。
- 一个动态库，包含真正的 arm64 和 versioned arm64e 两个切片。

## 安装和卸载

1. 使用 RootHide 环境中的 Sileo / Zebra 安装 `HideNCHeaders_1.0.5_arm64_arm64e_roothide.deb`。
2. **安装完成后重启桌面（Respring / Restart SpringBoard）。** 本包没有自动执行 Respring 的安装脚本。
3. 在锁屏、下拉通知中心分别展开至少两条同 App 的通知，检查分组头整行是否消失，通知卡片是否保留。
4. 没有设置图标是正常情况。要恢复，卸载本插件，再重启桌面。

这是 `iphoneos-arm64e` 架构的 **RootHide 包**，并非普通 `/var/jb` rootless 包；`iphoneos-arm64e` 是隐根包管理器使用的包架构字段，动态库本身仍为 arm64 + arm64e 双架构。不要对这份已针对隐根生成的包再次进行普通无根转换。若被包管理器拒绝，请反馈完整错误，不要强制忽略架构/依赖。

## iOS 版本限制

按要求移除安装包中 `Depends: firmware (>= 16.0), firmware (<< 17.0)`，不再由这组依赖限制安装的 iOS 版本。双架构、隐根包架构、作者名称、底部控制修复和签名动态库保持不变。

**取消包管理器的版本限制不等于全版本兼容。** 此次仅改安装元数据，没有伪造或降低动态库的系统版本标记：编译最低目标仍是 iOS 16.0；其他 iOS 版本上的私有类/接口与实际效果未验证，运行时只 hook 签名匹配的接口。本包仍适用于 RootHide 包管理环境，不能当作普通有根或 `/var/jb` 无根包。

## 本次修正（1.0.5）

用户 `photo_08A770A1.jpeg` 的红框显示：上部标题已隐藏，但另一组独立的底部「折叠 / ×」仍显示。本次在保留前版标题功能的基础上补齐底部路径：

- `NCNotificationListCoalescingControlsCell` 与 `NCNotificationListCoalescingControlsView` 分别安装独立可见性 hook；强制 hidden/alpha，生命周期先执行原实现再隐藏，关闭其命中和辅助功能暴露。没有按文字匹配任何通用按钮。
- 容器的 `+coalescingControlsCellHeightShowingCoalescingControls:` 及控件的 `+preferredHeight` 在精确签名匹配后返回零。
- 占位归零：`NCNotificationListView -_footerViewHeight` 与 `footerViewVerticalMargin` 仅针对隐藏的分组底部控制返回零；provider 的 `footerViewHeightForNotificationList:withWidth:` 及 `footerViewHeight` getter 同步处理。原始 cache/setter、边距 setter 保持原样，复用后不会留下写死的零值。
- 实际 list 已绑定的 footer 优先于 owner 的旧引用；遇到非目标摘要 footer、不同 owner/list 或无目标时保留原结果。不清除别的摘要、通知卡片或整个通知列表。
- 视图兜底：底部两类和原来的顶部两类各有独立原函数槽，frame/bounds/fit/intrinsic/system fitting 高度归零，宽度与原测量副作用保留。保留约 6 秒的有限启动重试，无永久轮询。
- 完成状态记录高度/可见性/几何/占位各步结果，部分失败不重挂已安装方法，也不误报完整成功。

公开 iOS 17 头文件与本机 SDK 16.5 导出支持上述定位；它们不是用户 iOS 16.3 真机视图转储，本次底部新增效果尚未真机复测。红框截图未提供精确类层级，因此仍需安装后验收。

## 保留的前版修正（1.0.3）

用户新截图中，分组标题及折叠/清除按钮已消失，但两个 App 的通知组之间仍有明显大空白。本次保留 1.0.2 的隐藏逻辑，补充标题的列表占位与数据源缓存处理：

- `NCNotificationListView -_headerViewHeight`：仅当实际标题是本插件已隐藏的新式/旧式标题，或它对应的 owner 持有该标题时返回零。
- `NCNotificationListPresentableGroup`、`NCNotificationStructuredSectionList`：对匹配的列表归零 `headerViewHeightForNotificationList:withWidth:` 及目标标题的 `headerViewHeight` getter。**原始缓存和 setter 保持原样**，标题更换/复用时可恢复原高度，不遗留被写死的零值。
- 视图兜底：仅对两种标题类的 `setFrame:` / `setBounds:` 保持零高度；`sizeThatFits:`、`intrinsicContentSize`、两种 Auto Layout fitting 尺寸也只将高度返回零，保留宽度和原测量调用。布局、入窗口及复用后再次收拢标题 bounds。**绝不把截图中的整个 NCNotificationListView 或卡片高度归零。**
- 保留原始测量调用的副作用；无标题、不同标题类型及不属于该 owner 的列表均保留原值。
- 不修改普通卡片高度，不改全局 `itemSpacing`、footer、frame、负 inset 或 transform；不靠手工挪动卡片遮掩占位。
- 插件显示名称改为「隐藏通知清除按钮」，作者及维护者改为 L.E，无设置页。

用户提供的视图检查截图确认存在嵌套 `NCNotificationListView`，外层 `(14,0)/(365,578)`、内层 `(0,88)/(365,490)`；被选中的容器同时包含通知卡片，不是纯标题，不能按类名将整个容器归零。这些 frame 不是固定待减高度，也未硬编码进插件。

这次空白修复尚未在 iOS 16.3 真机复测，截图只能证实 1.0.2 的标题隐藏已见效，不能视作 1.0.3 的间距已验收。

## 实现与边界

仅处理 SpringBoard 里的两种标题容器、两种分组控制视图及其匹配占位，不修改通知卡片和数据。底部逻辑见本次修正，保留的标题逻辑如下：

- 新式 `NCNotificationListCoalescingHeaderCell`：隐藏整个标题及其控件；仅当签名严格匹配时，将 `+coalescingHeaderCellHeightForWidth:title:` 设为零。
- 旧式 `NCNotificationListSectionHeaderView`：保留原隐藏逻辑，以及签名匹配时的 `+headerHeightWithWidth:title:isShowingCollapseButton:` 高度归零。
- 两类使用完全独立的原方法 IMP，分别安装；不会成功安装旧类就跳过新类。
- `setHidden:`、`setAlpha:` 强制保持隐藏；原 `layoutSubviews`、`didMoveToWindow`、`didMoveToSuperview` 先照常执行，再隐藏标题。
- 显式枚举本类方法：继承的方法只在目标类增加 override；添加失败也不会改写父类。没有全局 UIView / frame / bounds hook。
- 类型检查可接受编码后的十进制栈偏移，拒绝错误类型和参数数量；标量接口拒绝指针/block/结构体，几何兜底则逐参数严格匹配 `@encode(CGRect/CGSize/float)`，不靠猜测结构体调用约定。
- 显式链接系统 `UserNotificationsUIKit` 框架，让相关类在安装 hook 前可用。主线程有界启动重试，无永久轮询。
- 仅输出少量安装结果到系统日志，不写用户通知/联系人等内容，无设置页、无额外诊断程序。
- 不依赖写死的 `/var/jb`、RootHide 随机根目录或第三方 hook 库路径。

## 已做验证 / 未做验证

已做交叉编译、Mach-O 双架构与 versioned arm64e 标记、构造入口、系统依赖、代码签名逐页哈希、包内容及源码包 CRC 静态检查；两个架构均核对新旧标题类和高度 selector。

`tests/run_runtime_test.py` 从生产源码提取真实 hook，在 GNU ObjC 运行时与 UIView 模型上执行 205 条断言 / 600 次可见性与布局复用循环；保留前版 119 项回归，新增底部独立可见性/原函数链/复用零高、类高度、footer 占位与边距、原缓存保护、owner-list 一致性、摘要 footer 复用冲突隔离，以及卡片/整个列表几何尺寸不变。这是**本机模拟回归**，不等于 Apple UIKit、PAC 运行或真机注入测试。详情见 `verification.md`。

**没有在用户的 iOS 16.3 真机安装运行，不能将这些静态检查说成真机已测或保证零冲突。**

依据：本机 iPhoneOS 16.5 SDK 的 `UserNotificationsUIKit.tbd` 导出了目标类及 `_headerTitleView`、`_collapseButton`、`_clearButton` 等实例变量。公开 iOS 17 头文件可核对高度方法的名字及签名，Axon 旧实现可交叉核对标题类。它们是相关证据，不是 iOS 16.3 真机方法转储；因此代码在运行时做严格接口检查，未知接口不盲调用。

参考（均为接口证据，不是真机实现/调用链证明）：
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/UserNotificationsUIKit.framework/NCNotificationListCoalescingControlsCell.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/UserNotificationsUIKit.framework/NCNotificationListCoalescingControlsView.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/UserNotificationsUIKit.framework/NCNotificationListView.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/UserNotificationsUIKit.framework/NCNotificationListPresentableGroup.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/UserNotificationsUIKit.framework/NCNotificationStructuredSectionList.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/UserNotificationsUIKit.framework/NCNotificationListCoalescingHeaderCell.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/UserNotificationsUIKit.framework/NCNotificationListSectionHeaderView.h
- https://github.com/Baw-Appie/Axon/blob/master/Tweak/Tweak.xm （只作接口参考，没有复制该项目代码）
- https://github.com/roothide/theos/blob/master/vendor/mod/roothide/package/deb.mk
- https://github.com/roothide/theos/blob/master/vendor/mod/roothide/instance/library.mk

## 构建

- RootHide Theos：`make clean package FINALPACKAGE=1`，需其 arm64e ABI 兼容工具链及 iOS SDK。
- 当前 Alpine 交叉构建环境：`sh build.sh`。使用 LLVM 21 arm64/arm64e 编译、Apple ld64 链接、合并后 ldid 签名。SDK/工具链路径可通过环境变量覆盖。

本项目原创代码采用 MIT 许可。卸载和重启桌面可恢复原界面。若测试有问题，请提供锁屏/通知中心展开后的截图、当前越狱模式与安装错误或崩溃记录，再针对实际情况修正。
