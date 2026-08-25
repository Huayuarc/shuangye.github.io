# ChargeLimiter attribution

CPUthermal 1.6.4-24 的 SmartBatteryAPI 智能停充与自动禁流实现参考并移植自：

- Project: https://github.com/lich4/ChargeLimiter
- Upstream revision: `27d42eb1789744eee8e68cf69a806d2465bd2cd4`
- License: GNU General Public License v3.0

移植范围：`AppleSmartBattery` / `IOPMPowerSource` 服务选择，`PredictiveChargingInhibit` 停充，以及 `ExternalConnected` 禁流与恢复语义。CPUthermal 版本重写为独立 LaunchDaemon、共享偏好路径和阈值状态机。
