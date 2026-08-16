# PerfectSBVolume Dopamine 重写

基于 1.1-2 arm64 二进制静态逆向重建，不直接复用旧 arm64e ABI 00 切片。

- 注入：SpringBoard
- 私有类：`SBElasticVolumeViewController`、`SBVolumeHUDSettings`
- 行为：短按、长按和连续点按均保持细横条；State 1/2/3 的 getter 与 setter 全部统一。
- 尺寸：屏幕短边 22%，限制 80–94pt；高度 6pt、圆角 3pt、标签边距最大 4pt，不超过刘海窗口或灵动岛宽度。
- 兼容：iOS 15–17；同时约束 `preferredContentSize` 与布局后的实际 HUD 容器，阻止状态缓存重新放大。
- 目标：rootless `iphoneos-arm64` Dopamine / ElleKit，以及 RootHide `iphoneos-arm64e`。
- 私有类和 selector 存在性均在安装 Hook 前动态检查。
