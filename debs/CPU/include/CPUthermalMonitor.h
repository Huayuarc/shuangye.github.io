//
//  CPUthermalMonitor.h
//  CPUthermal
//
//  移植自 Battman (com.torrekie.Battman) thermal.h / thermal.c
//  通过 notify API 读取/写入系统热状态
//
//  使用注意事项:
//    - 所有函数都是纯 C，可在任意进程上下文中调用
//    - notify API 不需要特殊权限
//    - 设置函数 (set_*) 需要 platform-application 权限
//

#ifndef CPUTHERMAL_MONITOR_H
#define CPUTHERMAL_MONITOR_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// 热压级别枚举 (对应系统 kOSThermalNotificationPressureLevelName)
// Nominal(0) 正常, Light(10) 轻度, Moderate(20) 中度,
// Heavy(30) 重度, Trapping(40) 抑制, Sleeping(50) 休眠
// ============================================================================
typedef enum {
	kCPUthermalPressureNominal  = 0,
	kCPUthermalPressureLight    = 10,
	kCPUthermalPressureModerate = 20,
	kCPUthermalPressureHeavy    = 30,
	kCPUthermalPressureTrapping = 40,
	kCPUthermalPressureSleeping = 50,

	kCPUthermalPressureUnknown  = 99,
	kCPUthermalPressureError    = -1
} CPUthermalPressureLevel;

// ============================================================================
// OS 热通知级别枚举
// 对应 _OSThermalNotificationLevelForBehavior() 返回值
// ============================================================================
typedef enum {
	kCPUthermalNotifNormal            = 0,
	kCPUthermalNotif70PctTorch        = 1,
	kCPUthermalNotif70PctBacklight    = 2,
	kCPUthermalNotif50PctTorch        = 3,
	kCPUthermalNotif50PctBacklight    = 4,
	kCPUthermalNotifDisableTorch      = 5,
	kCPUthermalNotif25PctBacklight    = 6,
	kCPUthermalNotifDisableMapsHalo   = 7,
	kCPUthermalNotifAppTerminate      = 8,
	kCPUthermalNotifDeviceRestart     = 9,
	kCPUthermalNotifThermalTableReady = 10,

	kCPUthermalNotifNone    = -1,
	kCPUthermalNotifUnknown = 99
} CPUthermalNotifLevel;

// ============================================================================
// 热压读取
// ============================================================================

/// 获取当前系统热压级别 (通过 notify_get_state)
/// @return CPUthermalPressureLevel 枚举值，失败返回 kCPUthermalPressureError
CPUthermalPressureLevel CPUthermalPressure(void);

/// 将热压级别转换为可读字符串
/// @param pressure 热压级别
/// @return 静态字符串，如 "Nominal"、"Moderate" 等
const char *CPUthermalPressureString(CPUthermalPressureLevel pressure);

// ============================================================================
// 热通知级别
// ============================================================================

/// 获取当前 OS 热通知级别 (通过 OSThermalNotificationCurrentLevel)
/// @return CPUthermalNotifLevel 枚举值
CPUthermalNotifLevel CPUthermalCurrentNotifLevel(void);

/// 将通知级别转换为可读字符串
/// @param level 通知级别
/// @param withNumber 是否附加原始数值
/// @return 静态字符串
const char *CPUthermalNotifLevelString(CPUthermalNotifLevel level, bool withNumber);

// ============================================================================
// 热压写入（需要 platform-application 权限）
// ============================================================================

/// 手动设置热压级别 (通过 notify_set_state)
/// @param pressure 要设置的热压级别
/// @return 0=成功, 1=set失败, 2=post失败, -1=不支持
int CPUthermalSetPressure(CPUthermalPressureLevel pressure);

/// 重置热压力为 Nominal (正常)
/// @return 同 CPUthermalSetPressure
static inline int CPUthermalResetPressure(void) {
	return CPUthermalSetPressure(kCPUthermalPressureNominal);
}

// ============================================================================
// 传感器信息
// ============================================================================

/// 读取最大触发温度 (thermalmonitord 设置)
/// @return 摄氏度 (float)，失败返回 -1.0
float CPUthermalMaxTriggerTemperature(void);

/// 读取阳光暴晒状态 (thermalmonitord 设置)
/// @return 0=未暴晒, >0=暴晒中
int CPUthermalSolarState(void);

// ============================================================================
// 热通知写入
// ============================================================================

/// 手动设置热通知级别
/// @param level 要设置的通知级别
/// @return 0=成功, 1=失败, -1=不支持
int CPUthermalSetNotifLevel(CPUthermalNotifLevel level);

/// 重置热通知级别为 Normal
/// @return 同 CPUthermalSetNotifLevel
static inline int CPUthermalResetNotifLevel(void) {
	return CPUthermalSetNotifLevel(kCPUthermalNotifNormal);
}

#ifdef __cplusplus
}
#endif

#endif /* CPUTHERMAL_MONITOR_H */
