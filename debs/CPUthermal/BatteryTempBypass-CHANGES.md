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

## 与智能停充互斥

- `CPUthermalChargeTool` 通过 `smartChargeCutoffState` Darwin notify 发布断流状态，并在隐根状态文件持久化。
- 达阈值原子写入 `PredictiveChargingInhibit=true`、`ExternalConnected=false`、`IsCharging=false`。
- 智能停充断流时，BatteryTempBypass 保留温度伪装，但停止清除阻断位、原因位与恢复电流上限。
- 用户真实拔出再插入或电量降至阈值减 5% 后恢复；拔插恢复当前轮次设为手动覆盖，避免立即再次断流。
