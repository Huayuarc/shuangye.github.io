# CCSIM（含 iOS 17 卡死修复）

一个包搞定：`com.netskao.ccsim` 原版控制中心 SIM 开关 + iOS 17 卡死修复，不再需要另装 `CCSIMFix`。

## 为什么原来会卡死

CCSIM.bundle 由 SpringBoard 加载，它在**主线程**调用 CoreTelephony 的**同步** XPC 取值方法（签名从 iOS 16.1.2 的 CoreTelephony 上实读）：

```
-[CoreTelephonyClient getSIMStatus:error:]   enc=@32@0:8@16^@24
-[CoreTelephonyClient copyLabel:error:]      enc=@32@0:8@16^@24
```

这两个方法内部无超时地等 CommCenter 回复。iOS 17 上这个回复可能永远不来，SpringBoard 主线程被永久阻塞 —— 下拉控制中心、点一下开关就整机冻住，只能强重启。

## 怎么修

`CCSIMGuard.dylib` 注入 SpringBoard，**只在 iOS 17 及以上生效**（iOS 16 及更早一个 hook 都不装，行为与原版完全一致），把这一族同步取值方法换成"带超时的守卫调用"：

- 真正的调用放到后台串行队列执行，主线程最多等 **2 秒**；
- 超时返回 nil + `NSError`（domain `com.netskao.ccsim.guard`, code 1001），CCSIM 走自己的失败分支，不再冻结；
- 连续 2 次超时后熔断 **30 秒**，期间直接返回安全值，避免每次刷新都卡 2 秒；
- 覆盖 `getSIMStatus:`、`copyLabel:`、`getSimLabel:`、`getShortLabel:`、`copySIMIdentity:`、`getMobileEquipmentInfo(For:)`、`getSubscriptionInfoWithError`；
- 返回值所有权保守处理：一律把 retain 过的 +1 交出去，宁可泄漏一个对象，也不让调用方拿到已释放对象。

日志（`apelin_log_read` / Console）subsystem `com.netskao.ccsim`，关键字 `CCSIMGuard:`；启动 3 秒后打一行
`status hooked=1`（iOS 17+ 守卫已装）或 `iOS x.y < 17, CoreTelephony left untouched`（低版本不干预）。

## 目录

```
control              包信息（com.netskao.ccsim，Conflicts/Replaces com.huayuarc.ccsimfix）
CCSIMGuard.plist     注入过滤（com.apple.springboard）
Tweak.m              守卫实现（全部逻辑）
layout/              原版 CCSIM 的模块 bundle 与 CCSIMTool，原样打进同一个 deb
  DEBIAN/postinst    在 roothide 上补回 <binary>.roothidepatch 标记（prerm 负责删）
  Library/ControlCenter/Bundles/CCSIM.bundle/
  usr/local/bin/CCSIMTool
test/TestGuard.m     守卫逻辑离线自测（假的不返回实现、熔断路径）
test/TestDylib.m     把真 dylib 载进普通进程，验证 hook 装到真 CoreTelephonyClient 上
```

`layout/` 里的原版二进制不要改动内容；两个架构同一份。

## 为什么还要 postinst

原版 bundle 里写死了 `/var/jb/usr/local/bin/CCSIMTool` 这类路径，而 roothide 上真实不存在
`/var/jb`：那边靠二进制旁边的 `<path>.roothidepatch` 标记，让 roothide 载入时做路径补丁。
dpkg 升级会把原有标记软链删掉，结果就是"点开关没反应"。postinst 在
`/usr/lib/DynamicPatches/AutoPatches.dylib` 存在时（即 roothide）把它补回来，rootless 上自动跳过。

## 本地自测（iOS 16 上验证过）

```
cd tweaks/CCSIM
clang -arch arm64 -O1 -DCCSIMGUARD_TESTING -fno-objc-arc \
  -o test/guardtest Tweak.m test/TestGuard.m -framework Foundation
ldid -S test/guardtest && ./test/guardtest
```

预期：快速调用 0.000s 直通；卡住的调用 2.0s 截断返回 nil；再卡一次 2.0s 后熔断；熔断期内 0.000s 返回；真实 `getSIMStatus:error:` 经守卫正常返回（带原 NSError）。

本机工具链的 `ld` 不接受 `-undefined dynamic_lookup`（会报 `can't exec ld64`），所以
`MSHookMessageEx` 用 `dlsym` 取，dylib 没有未定义符号，`clang -dynamiclib` 可直接产出。
本机打包走 `apelin/build.sh`（`apelin_project_build`），正式包由 GitHub Actions（Theos，macOS）构建。

## 发布

`tweaks/CCSIM/` 是源码正本；发布时把它（不含 `test/`）复制到 `debs/CCSIM/`，递增 `control` 的 `Version`，提交并推送 `main`。CI 编完会删掉 `debs/` 下的源码。
