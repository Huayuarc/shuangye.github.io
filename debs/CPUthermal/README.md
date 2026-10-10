# CPUthermal 1.6.2-154+isolation.8

## 用户态预算实验

“解除温控”名称与 `fullPower` 偏好值保持不变。在现有支持的 CPU/GPU/Package 预算路径请求 Floor=100、Ceiling=100；CPU Level=0。这里的 100 是现工程的百分比预算请求，不是 MHz、瓦数、最大时钟、实际满功率或整个 SoC 硬锁。上一版 CPU Floor=100 已由用户真机反馈证实没有硬锁 A15；本版不能据此推断 GPU/Package 已被硬件采纳。

Package 表示共享功率预算，不是独立的 SoC 全模块控制协议，不包含神经引擎、ISP、射频等模块各自的 floor。独立 SoC Floor：`not_verified/not_implemented`。已精确搜索基线、项目头文件及参考包的 selector/ObjC 分析材料，未找到可验证的独立 SoC floor setter 或真实 IOKit 键，更没有其百分比单位、owner/source、返回 ABI 的证据。因此不猜测 `setSoCPowerFloor:`、不改名冒充，不增加未知 IOConnect 调用或寄存器写入。继续实现需对应设备系统 thermalmonitord/framework 的接口与调用材料、完整方法编码、百分比单位及 source 语义证据。

## 模式与恢复

- full：CPU/GPU/Package Floor/Ceiling 请求 100，CPU Level0。CommonProduct 与 MitigationController 路径均覆盖；来源沿用现工程 0..5（源码假定，共 6 个），不猜新枚举。
- low：CPU 保留 2500mW / Ceiling45% / Level2 / Floor0；主动清掉 GPU/Package 所有已有来源的 Floor100，请求 Floor0，防止 full→low 残留。清理函数不调用 full 恢复，不误回 Level0，不启用全局 PowerSave，不改变亮度。
- disabled：追踪控制器和 CommonProduct 的 CPU/GPU/Package floors 清零，原更新后再清一次，再交还原生预算。卸载仍使用原 prerm 的 thermalmonitord 重启清理运行态，不 kill powerd；卸载实际恢复效果待真机验证。
- GPU/Package floor setter hook 仅在目标方法存在、返回 `void`、隐含参数 `@`/`:`、两个显式整数参数的完整编码匹配时安装；仅接受 `i/I/q/Q` 精确组合，单个声明 owner/class/selector 去重。继承路径不重复安装；未知 ABI 保留原实现。
- 主动发送使用 `respondsToSelector` 加完整类型检查；第一个 floor 参数和第二个 source 参数都按实际 signed/unsigned 32/64 位类型发送，不把对象或指针强转整数。
- 每次原 updateGPU/updatePackage 后仅在同线程有界重申共享预算，以 thread-local guard 防递归。不新增高频 timer、每秒 setter 循环、UI observer 或跨线程 floor 测试任务。

## 保持不变

DisplayGuard、PrefHook、充电、控制中心、路径解析、频率读取、原维护脚本模板与 Makefile 不改。四核心 tweaks 保留：CPUthermal、CPUthermalPrefHook、CPUthermalFaceDownLock、CPUthermalDisplay。isolation.6 已删除的刷新率强制功能和诊断文件日志不重引入。硬件/固件紧急保护不修改。

## 风险与验证

更高预算请求可能明显增加发热与耗电。电池电压下垂、电流/功率限制和硬件保护可能反而降低性能；不能保证持续最大时钟、帧率或实际满功率。保护仍可接管，请勿通过危险升温验证。

选择对应环境的一个 DEB：Rootless 或 RootHide。安装/升级脚本重启 thermalmonitord 并重新加载充电守护；安装后手动重启用户空间，使其他已运行进程重新载入插件。

本地 `python3 -m unittest discover -s tests -v` 是静态合同、ABI 宏编译与模式模型验证，不是真机运行验证。用户截图里的新 CPU/GPU/Package 值、接口支持情况、预算是否被采纳、full→low→full→disable 和卸载恢复，都需要真机验证；不能把请求值或截图数值当成整个 SoC 已满功率的证明。
