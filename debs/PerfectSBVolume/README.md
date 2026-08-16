# PerfectSBVolume Dopamine 重写

基于 1.1-2 arm64 二进制静态逆向重建，不直接复用旧 arm64e ABI 00 切片。

- 注入：SpringBoard
- 私有类：`SBElasticVolumeViewController`、`SBVolumeHUDSettings`
- 行为：横向音量条；State 1/3 复用 State 2 尺寸；隐藏标签更新；宽度 150、标签边距 100；按屏幕高度调整到刘海下方。
- 目标：rootless `iphoneos-arm64`，Dopamine / ElleKit。
- iOS 16 私有类和 selector 存在性均在安装 Hook 前动态检查。
