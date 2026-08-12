# PictureModule 16

面向 iOS 16 重写的原生控制中心图片/视频模块，不链接旧 PictureModule.framework、Preferences.framework 或 oldabi 兼容层。

## 功能

- 5 个相互独立的控制中心模块
- 控制中心长按展开后，通过系统 PHPicker 选择图片或视频
- 图片/视频：裁切、适应、拉伸三种显示模式
- 100% / 75% / 50% / 25% 透明度
- 视频静音循环播放
- rootless 与 roothide 双架构打包
- 数据保存在 `/var/mobile/Library/PictureModule`（rootless 环境对应 `/var/jb/var/mobile/Library/PictureModule`）

## 使用

安装后重启用户空间，在“设置 → 控制中心”添加“图片模块 16（1～5）”。长按模块进入展开界面，点“选择”导入图片或视频。

## 构建

```sh
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
```
