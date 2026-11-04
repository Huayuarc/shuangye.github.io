# CCSIMFix

给 `com.netskao.ccsim`（CCSIM 控制中心 SIM 开关）打的兜底补丁：**解决 iOS 17 上拉/点控制中心里的 CCSIM 开关时整机卡死、只能强制重启的问题**。

## 为什么卡死

CCSIM.bundle 由 SpringBoard 加载，它在**主线程**调用 CoreTelephony 的同步 XPC 取值方法（签名从 iOS 16.1.2 的 CoreTelephony 上实读）：

```
-[CoreTelephonyClient getSIMStatus:error:]   enc=@32@0:8@16^@24
-[CoreTelephonyClient copyLabel:error:]      enc=@32@0:8@16^@24
```

这两个方法内部阻塞等待 CommCenter 回复，本身没有超时。iOS 17 上这个回复可能永远不来，于是 SpringBoard 主线程被永久阻塞 —— 下拉控制中心、点一下开关就整机冻住。

## 怎么修

Dylib 注入 SpringBoard，把这类同步取值方法换成"带超时的守卫调用"：

- 真正的调用放到后台串行队列执行，主线程最多等 **2 秒**；
- 超时返回 nil + `NSError`（domain `com.huayuarc.ccsimfix`, code 1001），CCSIM 走它自己的失败分支，不再冻结；
- 连续 2 次超时后熔断 **30 秒**，期间直接返回安全值，避免每次刷新都卡 2 秒；
- 覆盖 `getSIMStatus:`、`copyLabel:`、`getSimLabel:`、`getShortLabel:`、`copySIMIdentity:`、`getMobileEquipmentInfo(For:)`、`getSubscriptionInfoWithError` 这一族同步接口。

日志（`apelin_log_read` / Console）subsystem `com.huayuarc.ccsimfix`。

## 目录

- `Tweak.m` — 全部实现；
- `CCSIMFix.plist` — 注入过滤（com.apple.springboard）；
- `test/TestGuard.m` — 守卫逻辑离线自测（含假的不返回实现、熔断路径）；
- `test/TestDylib.m` — 把真 dylib 载进普通进程验证 hook 装到真 `CoreTelephonyClient` 上。

## 本地自测（iOS 16 上验证过）

```
cd tweaks/CCSIMFix
clang -arch arm64 -O1 -DCCSIMFIX_TESTING -fno-objc-arc \
  -o guardtest Tweak.m test/TestGuard.m -framework Foundation
ldid -S guardtest && ./guardtest
```

输出应为：快速调用 0.000s 直通；卡住的调用 2.0s 截断返回 nil；第二次再卡 2.0s 后熔断；熔断期内 0.000s 返回；真实 `getSIMStatus:error:` 经守卫正常返回。

注意：本机工具链的 `ld` 直接 `-dynamiclib` 会报 `can't exec ld64`，所以 dylib 用
`clang -c` 再 `ld -dylib -arch arm64 -platform_version ios 15.0 16.0 -undefined dynamic_lookup` 两步链接；
正式包由 GitHub Actions（Theos，macOS）构建。

## 发布

`tweaks/CCSIMFix/` 是源码正本；`debs/CCSIMFix/` 是给 CI 的临时副本（CI 编完会删掉 `debs/` 下源码）。
发布时把源码（不含 test/）复制到 `debs/CCSIMFix/`，递增 `control` 里的 `Version`，提交并推送 `main`。
