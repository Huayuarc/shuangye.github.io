//
//  CPUthermalMonitor.c
//  CPUthermal
//
//  移植自 Battman (com.torrekie.Battman) battery_utils/thermal.c
//  通过 notify API 读取/写入系统热状态
//
//  依赖:
//    - notify.h (系统框架)
//    - dlfcn.h (动态加载 OSThermalNotification)
//    - 写入操作需要 platform-application 权限
//

#include "CPUthermalMonitor.h"

#include <notify.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include <TargetConditionals.h>

// ============================================================================
// OSThermalNotification 符号 — 通过 dlopen 动态解析
// ============================================================================

// kOSThermalNotificationPressureLevelName 是 notify key
// 在 iOS/Mac 上通过 __DATA 段符号导出
static const char *get_thermal_pressure_key(void) {
	static const char *key = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		// 从系统库中获取 kOSThermalNotificationPressureLevelName
		void *sym = dlsym(RTLD_DEFAULT, "kOSThermalNotificationPressureLevelName");
		if (sym) {
			key = *(const char **)sym;
		}
		if (!key) {
			// 兜底硬编码值
			key = "com.apple.system.thermalpressurelevel";
		}
	});
	return key;
}

static const char *get_thermal_notif_name(void) {
	static const char *name = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		void *sym = dlsym(RTLD_DEFAULT, "kOSThermalNotificationName");
		if (sym) {
			name = *(const char **)sym;
		}
		if (!name) {
			name = "com.apple.system.thermalnotificationlevel";
		}
	});
	return name;
}

// OSThermalNotificationCurrentLevel() — 通过 dlopen 获取
typedef int (*OSThermalCurrentLevelFunc)(void);
static OSThermalCurrentLevelFunc get_thermal_current_level(void) {
	static OSThermalCurrentLevelFunc func = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		func = (OSThermalCurrentLevelFunc)dlsym(RTLD_DEFAULT, "OSThermalNotificationCurrentLevel");
	});
	return func;
}

// ============================================================================
// 热压级别名称表
// ============================================================================
static const char *g_pressure_names[] = {
	"Nominal",
	"Light",
	"Moderate",
	"Heavy",
	"Trapping",
	"Sleeping"
};

static const int g_pressure_count = sizeof(g_pressure_names) / sizeof(g_pressure_names[0]);

// ============================================================================
// 热通知级别名称表
// ============================================================================
static const char *g_notif_names[] = {
	"Normal",
	"70% Torch",
	"70% Backlight",
	"50% Torch",
	"50% Backlight",
	"Torch Disabled",
	"25% Backlight",
	"Maps Halo Disabled",
	"App Terminated",
	"Device Restart",
	"Ready"
};

static const int g_notif_count = sizeof(g_notif_names) / sizeof(g_notif_names[0]);

// ============================================================================
// 热压读取
// ============================================================================

CPUthermalPressureLevel CPUthermalPressure(void) {
	int token;
	uint64_t level;

	// 通过 notify API 读取热压级别
	const char *key = get_thermal_pressure_key();
	if (!key) return kCPUthermalPressureError;

	if (notify_register_check(key, &token)) {
		return kCPUthermalPressureError;
	}
	if (notify_get_state(token, &level)) {
		notify_cancel(token);
		return kCPUthermalPressureError;
	}
	notify_cancel(token);

	// 映射数值到枚举
	switch (level) {
		case 0:
			return kCPUthermalPressureNominal;
		case 10:
			return kCPUthermalPressureLight;
		case 20:
			return kCPUthermalPressureModerate;
		case 30:
			return kCPUthermalPressureHeavy;
		case 40:
			return kCPUthermalPressureTrapping;
		case 50:
			return kCPUthermalPressureSleeping;
		default:
			// 兼容旧式级别 (1-4)
			if (level >= 1 && level <= 4) {
				return (CPUthermalPressureLevel)(level * 10);
			}
			return kCPUthermalPressureUnknown;
	}
}

const char *CPUthermalPressureString(CPUthermalPressureLevel pressure) {
	int idx = -1;

	switch (pressure) {
		case kCPUthermalPressureNominal:  idx = 0; break;
		case kCPUthermalPressureLight:    idx = 1; break;
		case kCPUthermalPressureModerate: idx = 2; break;
		case kCPUthermalPressureHeavy:    idx = 3; break;
		case kCPUthermalPressureTrapping: idx = 4; break;
		case kCPUthermalPressureSleeping: idx = 5; break;
		default:                          idx = -1; break;
	}

	if (idx >= 0 && idx < g_pressure_count) {
		return g_pressure_names[idx];
	}

	static char unknown[32];
	snprintf(unknown, sizeof(unknown), "Unknown (%d)", (int)pressure);
	return unknown;
}

// ============================================================================
// 热通知级别读取
// ============================================================================

CPUthermalNotifLevel CPUthermalCurrentNotifLevel(void) {
	OSThermalCurrentLevelFunc func = get_thermal_current_level();
	if (!func) {
		return kCPUthermalNotifNone;
	}

	int rawLevel = func();
	if (rawLevel < 0) {
		return kCPUthermalNotifNone;
	}

	// 尝试匹配已知级别
	if (rawLevel < g_notif_count) {
		return (CPUthermalNotifLevel)rawLevel;
	}

	return kCPUthermalNotifUnknown;
}

const char *CPUthermalNotifLevelString(CPUthermalNotifLevel level, bool withNumber) {
	static char buf[64];

	int idx = -1;
	if (level >= 0 && level < g_notif_count) {
		idx = (int)level;
	}

	if (idx >= 0) {
		if (withNumber) {
			snprintf(buf, sizeof(buf), "%s (%d)", g_notif_names[idx], idx);
		} else {
			snprintf(buf, sizeof(buf), "%s", g_notif_names[idx]);
		}
	} else {
		snprintf(buf, sizeof(buf), "None");
	}

	return buf;
}

// ============================================================================
// 热压写入
// ============================================================================

int CPUthermalSetPressure(CPUthermalPressureLevel pressure) {
	uint64_t level = 0;
	int token;

	const char *key = get_thermal_pressure_key();
	if (!key) return -1;

	if (notify_register_check(key, &token)) {
		return -1; // 不支持
	}

	// 映射枚举到数值
	switch (pressure) {
		case kCPUthermalPressureLight:    level = 10; break;
		case kCPUthermalPressureModerate: level = 20; break;
		case kCPUthermalPressureHeavy:    level = 30; break;
		case kCPUthermalPressureTrapping: level = 40; break;
		case kCPUthermalPressureSleeping: level = 50; break;
		default:                          level = 0;  break; // Nominal
	}

	if (notify_set_state(token, level)) {
		notify_cancel(token);
		return 1; // set 失败
	}

	// 广播通知，让系统感知变化
	if (notify_post(key)) {
		notify_cancel(token);
		return 2; // set 成功但 notify 失败
	}

	notify_cancel(token);
	return 0; // 成功
}

// ============================================================================
// 热通知级别写入
// ============================================================================

int CPUthermalSetNotifLevel(CPUthermalNotifLevel level) {
	int token;
	uint64_t value = (level >= 0 && level < g_notif_count) ? (uint64_t)level : 0;

	const char *name = get_thermal_notif_name();
	if (!name) return -1;

	if (notify_register_check(name, &token)) {
		return -1; // 不支持
	}

	if (notify_set_state(token, value)) {
		notify_cancel(token);
		return 1; // 失败
	}

	if (notify_post(name)) {
		notify_cancel(token);
		return 2; // 成功但 notify 失败
	}

	notify_cancel(token);
	return 0; // 成功
}

// ============================================================================
// 传感器信息
// ============================================================================

float CPUthermalMaxTriggerTemperature(void) {
	int token;
	uint64_t level;

	if (notify_register_check("com.apple.system.maxthermalsensorvalue", &token)) {
		return -1.0f;
	}
	if (notify_get_state(token, &level)) {
		notify_cancel(token);
		return -1.0f;
	}
	notify_cancel(token);

	// thermalmonitord 上报的单位是百分之一摄氏度
	return (float)level / 100.0f;
}

int CPUthermalSolarState(void) {
	int token;
	uint64_t level;

	if (notify_register_check("com.apple.system.thermalsunlightstate", &token)) {
		return 0;
	}
	if (notify_get_state(token, &level)) {
		notify_cancel(token);
		return 0;
	}
	notify_cancel(token);

	return (int)level;
}
