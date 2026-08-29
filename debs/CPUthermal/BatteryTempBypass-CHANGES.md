# BatteryTempBypass 集成说明

## 注入与兼容

- 仅注入 `powerd`，不注入 `thermalmonitord`。
- Rootless 与 RootHide 共用同一源码及 `CPUthermalPaths.h`；动态解析当前 `.jbroot-*`，无隐根时回退 `/var/jb`。
- 覆盖 `IORegistryEntryCreateCFProperties`、`IORegistryEntryCreateCFProperty`、`IORegistryEntrySearchCFProperty`、`IORegistryEntrySetCFProperty`、`IORegistryEntrySetCFProperties`。
- Registry 写入拦截只作用于已缓存的电池/充电管理器服务 ID。

## 屏蔽高温停充

- 按原值量纲把常见电池温度键归一为 32°C。
- 清除高温停充布尔位及 `BatteryNotChargingReason`、`NotChargingReason`、`ChargeInhibitReason` 等原因码。
- 缓存设备自身的正常 `MaxChargeCurrent`、`NominalChargeCurrent`、`ChargeCurrentLimit`；高温策略写入 0 时恢复缓存，不硬编码固定机型电流。
