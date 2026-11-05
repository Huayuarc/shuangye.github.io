# AGENTS.md — 本工作区怎么干活

这个仓库是用户在 GitHub Pages 上的 Cydia/Sileo 源（`https://huayuarc.github.io`），
同时充当各插件的构建入口。**它不是 Apelin 的构建描述工程，`apelin_project_build` 走
`apelin/build.sh`。**

## 两条构建路线

1. **正式发行（GitHub Actions / macOS + roothide Theos）**
   `.github/workflows/build-theos.yml` 监听 `debs/**` 的推送：对 `debs/` 下每个带
   `Makefile` 且含 `TWEAK_NAME|TOOL_NAME|APPLICATION_NAME` 的工程，依次用
   `THEOS_PACKAGE_SCHEME=rootless`（arm64）和 `roothide`（arm64e）编译打包，把
   `packages/*.deb` 提交回 `main`，然后清理源码目录里的构建产物（`.theos/`、`obj/`、
   `packages/`、`*.dSYM`），**源码永久保留在 `debs/<工程>/`**（2026-11 起不再编译后删源码）。
   - 所以：`debs/<工程>/` 就是源码正本，直接在原地改；`tweaks/<工程>/` 是 CCSIM 的历史位置。
   - `packages/` 里的旧包会被保留，只覆盖同名产物（改过这一步，别再改成清空）。
   - 失败日志在 `build-logs` 分支的 `errors/build-run-<run_id>.txt`。
2. **本机（设备上，iOS 16 环境）**
   `apelin_project_build` 跑 `apelin/build.sh`：按 `APELIN_BOOTSTRAP` 选架构编译
   dylib、`ldid -S` 签名、拼 `DEBIAN/control`、`dpkg-deb` 出包；产物用
   `apelin_package_install` 装、`apelin_package_confirm_loaded` 确认注入
   （脚本会带 `-DAPELIN_BUILD_ID`，构造函数打印 `ApelinLoaded <id>`）。

## 本机工具链的坑

- 本机 `ld` 不接受 `-undefined dynamic_lookup`（会报 `can't exec ld64`）。dylib 里不要留
  未定义符号：substrate 的 `MSHookMessageEx` 一律用 `dlsym(RTLD_DEFAULT, ...)` 取。
- 编译器的 `/tmp` 与 bootstrap shell 的 `/tmp` 不是同一个（roothide），产物写工程内相对路径。
- 用 `clang -arch arm64e -dynamiclib -fno-objc-arc -framework Foundation` 即可。

## 现有插件

- `tweaks/CCSIM/`：`com.netskao.ccsim`（CCSIM 控制中心 SIM 开关）与其 iOS 17 卡死修复
  合并成一个包：`layout/` 里是原版 bundle/工具，`Tweak.m` 是注入 SpringBoard 的
  `CCSIMGuard.dylib`。细节与自测方法见该目录 `README.md`。

## roothide 上的路径补丁标记

原版 CCSIM.bundle 里写死了 `/var/jb/...` 路径，roothide 真实没有 `/var/jb`，靠二进制旁边的
`<binary>.roothidepatch` 软链（指向 `/usr/lib/DynamicPatches/AutoPatches.dylib`）让 roothide 在载入时
做路径补丁。dpkg 升级会把这类标记删掉，所以 `tweaks/CCSIM/layout/DEBIAN/postinst` 负责补回，
`prerm` 负责删除。以后凡是打包“非本工程编译的上游二进制”，都要检查这个标记。

## CPUthermal 的 CPU 降频取证（isolation.54）

用户报告“解除温控下用着变卡、频率极低、几分钟自恢复”时的排查顺序：

1. `diag/ThermalProbe`（源码 `diag/ThermalProbe.m`，`clang -arch arm64e -fobjc-arc -framework Foundation` 后 `ldid -Sdiag/Tool.entitlements`）读 IORegistry：
   - `AppleCLPC` 的 `` `pkg-avg-therm-power-target `` / `` `pkg-low-power-target `` 应为 `-16777216`（Q24 的 -1.0，即不限）。是负一说明**解除温控的写入生效且未被回滚**。
   - `ApplePPM` 看 `UseOverrideSystemCapability`、`UseOverrideClientPowerBudgets`，都为 0 说明 PPM 未叠加限频。
2. 两处都不限而仍然掉频 → 问题在 thermalmonitord 的 `MitigationController` / `CommonProduct` 钩子，不在硬件预算层。
   已知坑（isolation.54 修）：`setCPMSMitigationsEnabled:` 旧实现只在 enabled=NO 时转发 NO，等效于把系统自己发起的 CPMS 缓解一并吞掉；契约固化为
   `debs/CPUthermal/tests/test_isolation54.py`——低功耗强制 YES、解除温控强制 NO、其余原样 `%orig(enabled)`。
3. IOReport（`CPU Stats` 通道）这条路在 iOS 16.1.2 / arm64e 上 `IOReportCreateSubscription` 会撞 PAC（SIGBUS/SIGSEGV），
   别在上面耗时间；CLPC + PPM 的 IORegistry 键已经够用。
4. 回归：`cd debs/CPUthermal/tests && python3 -m unittest discover -p 'test_*.py'`（当前 184 项）。

## 防温控暗屏（isolation.57）

用户要求“系统触发暗屏时人眼不能发现”，实现为三层，缺一层就会看到掉亮度：

1. **事前拦截（写入路径）** `debs/CPUthermal/CPUthermalDisplayShield.xm`
   注入 backboardd/brightnessd/displaypolicyd/SpringBoard，命中“满档断崖”即丢弃写入并返回 `KERN_SUCCESS`：
   当前 `IOMFBBrightnessLevel` ≥ `BLNitsCap` 的 90%、新值 < 90%、面板温度 ≥ 36°C。
   零值/关屏指令一律放行，判定只用本地 IORegistry 读取（在 backboardd 里做跨进程调用会自锁黑屏，isolation.45 教训）。
2. **秒级恢复** `debs/CPUthermal/Tools/CPUthermalDisplayTool.m`（LaunchDaemon `com.huayuarc.cputhermal.display`）
   每 0.5s 巡检、0.5s 冷却、0.35s 判定；未学到样本但面板级跌到请求一半以下时按请求 85% 抬回；
   每 5s 记录 `panel-limited` 日志（主机侧已抬满、`NitsPhysical` 仍低＝面板/DCP 层压暗）。
3. **核心兜底** `Tweak.x` 的 `CPUthermalFastCapTick`（0.5s，只读 `AppleCLCD2`/`AppleCLCD` 的 `BLNitsCap`、`brightness-nits`）
   与 `CPUthermalBacklightAuditTick`（5s 全树兜底）。核心绝不写 `IOMFBBrightnessLevel`（契约测试强制）。

**面板温补这一层关不掉**（2026-11 实测，iPhone 14,2 / 16.1.2 / roothide）：
`AppleCLCD2` 上 `DisableTempComp=0`、`IOMFBTemperatureCompensationEnable=1`、`enable2DTemperatureCorrection=1`，
即使 uid 0 写入也返回 `kIOReturnNotPrivileged`（0xE00002C2）——补偿在 DCP 固件里，主机侧无法关闭。
`APTPDCTemperature` 是面板自报温度（39–41°C 常态），`Brightness_Scale` 随它变化。

诊断工具（未跟踪，不入库）：`diag/BrightWatch`（采样）、`diag/CBDump`（CoreBrightness 属性）、
`diag/TempComp`（温补键读取/写入测试）、`diag/SetKey`（任意 IORegistry 写测试，`mobile` 即可写 `IOMFBBrightnessLevel`）。

## 验证习惯

- 改动后先跑 `tweaks/CCSIM/test/` 里的离线自测（`clang ... Tweak.m test/TestGuard.m`）。
- 装上设备后看 `apelin_log_read`（subsystem `com.netskao.ccsim`）里的
  `status hooked=1`（iOS 17+ 守卫已装）或 `iOS x.y < 17, CoreTelephony left untouched`（低版本不干预），再看控制中心里磁贴是否还在。
