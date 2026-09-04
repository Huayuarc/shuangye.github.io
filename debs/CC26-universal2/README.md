# CC26 0.6.0.1-universal2

以用户上传的 `CC26-0.6.0.0-universal1-source.zip` 为主线，并使用用户上传的
`CC26-0.4.9.9b-iphoneos-arm64.deb` 核心作为可复现基线。

## 基线证明

上传 DEB 中 `CC26.dylib`：

- SHA-256：`d06ef3a0708d1adf21cf661d000f48a8985f6e66ec0b57964bb9e1298e8c161d`
- 架构：arm64 + PAC00 arm64e
- 与原作者 Git 历史 `19c89f6` 内 `com.cureux.cc26_0.4.9.9b_iphoneos-arm64.deb` 的 dylib 字节完全一致。
- universal1 全部 40 个补丁位点均与预期原字节精确匹配。

补丁输出 `CC26Core.dylib`：

- SHA-256：`83ac870ccfdd4eceb76c37e7bf83a40ec46bed4a358f0909868a468c9980b0e0`

`patch_cc26.py` 同时保留原 universal1 README 中 nomedia3 基线的严格白名单支持。

## 跨版本设计

预编译核心本身不直接注入 SpringBoard。可编译的 `CC26Loader.dylib` 先检查：

1. 当前进程是 SpringBoard；
2. 系统主版本是 iOS 15 或 iOS 16；
3. `MTMaterialLayer` 与 `CCUIModularControlCenterOverlayViewController` 存在；
4. `_configureIfNecessaryWithSettingsInterpolator:` selector 存在；
5. 设置面板 `Enabled` 没有关闭。

全部通过后，Loader 才从同目录 `dlopen("CC26Core.dylib")`。iOS 17+ 默认不加载核心，
防止 ControlCenter 与 System Aperture 私有类布局改变导致 SpringBoard 崩溃。

核心继续保留 universal1 的稳定补丁：

- 媒体控制中心修改中和；
- 音量 HUD 兼容；
- 中文电源菜单和长按交互；
- CCSIM 点击兼容；
- arm64/arm64e 两个切片的 `applyBorderToSpecialViews()` 入口直接返回，停止全局特殊边框递归。

## 设置面板

参考用户提供 `scripts.zip`，使用真正编译的 `PSListController`、动态 `PSSpecifier`、
`CFPreferences` 与 Darwin 通知。只有“启用 CC26”是运行时有效开关；修改关闭状态后需要注销桌面，
因为已经安装的 Logos hooks 不适合在运行中的 SpringBoard 内卸载。

## 构建

工程由仓库 `Build Theos Projects` 工作流构建：

- rootless：`iphoneos-arm64`
- RootHide：`iphoneos-arm64e`

`before-all` 会先运行 `patch_cc26.py`，任何基线哈希或补丁位点不匹配都会使构建失败。
