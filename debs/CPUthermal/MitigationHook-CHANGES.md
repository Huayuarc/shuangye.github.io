# CPUthermal 1.6.4-50 · MitigationHook 补充完善说明

把附件 `MitigationHook.xm.txt`（SBCPUFloating 风格底层拦截）补充完善进 `cpu.zip`
源工程，新增一个独立的 `CPUthermalMitigationHook.dylib`，提供「硬件写边界绝杀拦截」。

## 变更概览

| 文件 | 操作 | 说明 |
|---|---|---|
| `MitigationHook.xm` | 新增 | 新 dylib 主逻辑 |
| `CPUthermalMitigationHook.plist` | 新增 | Filter：thermalmonitord + powerd |
| `include/CPUthermalPaths.h` | 修改 | 新增 mitigation 位打包通知常量与 helper |
| `Makefile` | 修改 | 新增 `CPUthermalMitigationHook` tweak 目标 + roothide LDFLAGS |
| `Settings/FRootListController.m` | 修改 | 开关/功率模式变化时发布 mitigation 状态 |

## 新增机制（相比原工程的增量）

原工程已有上层分工：
- `Tweak.x`：MitigationController / CommonProduct 等 **ObjC 级**功率目标拦截（thermalmonitord）
- `BatteryTempBypass.xm`：`IORegistryEntryCreateCFProperties` **读边界**温度夹紧 + 周期清抑制位（powerd）

新 dylib 在更底层补上 **写边界**：
- Hook `IORegistryEntrySetCFProperty`，拦截 thermalmonitord/powerd 向 IOKit **写入**的降亮度属性
  （`max-brightness`/`brightness-limit`/`IOMFB_brightness_limit`/`ThermalMitigation`/`ThermalLimit`），热点状态可直接吞掉 → 物理层阻断热降亮度；
- 强制满血快充：把 `ChargeCurrent`/`ChargeLimit`/`MaxChargeCurrent`/`ChargeRate` 注入 5000；
  清 `ChargeInhibit`/`SmartCharge`/`EnforceDisableOBC`；
- 按模式钳制 CPU 节流属性（`p-state-cap`/`CPU_Ceiling`/`CPU_Floor`）。
- 1s 周期复施功率目标（仅 thermalmonitord）。

## 驱动信号

新增 Darwin 通知 `com.huayuarc.cputhermal/mitigationState`（位打包）：
- `bit0`（MIT_CPU_MODE_LOW）＝ 低功耗(1) / 解除温控(0)
- `bit8`（MIT_BLOCK_DIMMING）＝ `thermalPreventDimmingEnabled`
- `bit9`（MIT_FORCE_FAST_CHARGE）＝ `forceFastChargeIgnoreHeat`

设置面板在 `setPreferenceValue` 与 `viewWillAppear` 中，于相关开关/功率模式变化时统一通过
`CPUthermalPostMitigationState` 发布；dylib 订阅 `settingsChanged` + `powerModeChanged` 并
在启动时同步一次，热路径只读 notify state，零磁盘开销。

## 规避双重 Hook

- MitigationController 的 ObjC 级 Hook 全部保留在 Tweak.x，本 dylib **不复刻**，
  因此 thermalmonitord 内不会出现同方法双重 Hook；
- 写边界与 BatteryTempBypass 读边界是不同函数、不同语义（写 vs 读），二者共存为上下双层保险。
