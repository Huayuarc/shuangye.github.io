# Snapper About Hide 1.0.0

独立插件，只对 `com.axs.snapper4.prefs` Bundle 内的 `Snapper4RootListController -specifiers` 进行过滤。

精确移除连续的四个条目：关于我们、Sileo 越狱源、TG 分享频道、QQ 交流群组。只有四项标签完整匹配时才执行删除，保留其他所有条目及它们原来的对象、顺序、回调和配置。

- 仅注入 `com.apple.Preferences`。
- 不覆盖、不修改 Snapper4Prefs 二进制或任何原插件文件。
- 支持偏好 Bundle 延迟加载，监听 NSBundleDidLoadNotification。
- 同步更新 PSListController 的 `_specifiers` 缓存，避免表格仍显示原始行。
- 没有设置面板、配置文件、后台任务、联网或日志。
- 安装后关闭设置应用，再重新打开 Snapper4 面板；若注入未刷新，重启用户空间。
- 卸载本插件并重开设置即可恢复原来的关于我们。

构建：

```sh
make clean package THEOS_PACKAGE_SCHEME=rootless ARCHS=arm64 FINALPACKAGE=1
make clean package THEOS_PACKAGE_SCHEME=roothide ARCHS="arm64 arm64e" FINALPACKAGE=1
```

参考样本：com.axs.snapper4 5.2.0-45；Root.plist 不含关于我们，二进制含 addAboutGroup/openSileoRepo/openTelegramChannel/openQQGroup，四个标签以 UTF-16LE 存储。采用 specifiers 过滤避免依赖私有 addAboutGroup 方法的签名。

静态检查和 CI 编译不等同于真机 UI 验证。未来版本若改变四个标签或顺序，会保持原面板，不扩大删除范围。
