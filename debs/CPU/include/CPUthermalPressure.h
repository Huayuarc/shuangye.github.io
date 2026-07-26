#ifndef CPUTHERMAL_THERMAL_PRESSURE_H
#define CPUTHERMAL_THERMAL_PRESSURE_H

#import <Foundation/Foundation.h>
#import <notify.h>
#import <dlfcn.h>
#import <os/base.h>

// ============================================================================
// 热压力级别枚举（对应 OSThermalPressureLevel）
// 移植自 Battman thermal.h
// ============================================================================
typedef NS_ENUM(NSInteger, CPUthermalPressureLevel) {
    CPUthermalPressureLevelError    = -1,
    CPUthermalPressureLevelNominal  = 0,   // 正常
    CPUthermalPressureLevelLight    = 10,  // 轻微
    CPUthermalPressureLevelModerate = 20,  // 中等
    CPUthermalPressureLevelHeavy    = 30,  // 严重
    CPUthermalPressureLevelTrapping = 40,  // 临界
    CPUthermalPressureLevelSleeping = 50,  // 休眠

    CPUthermalPressureLevelUnknown  = 999
};

// ============================================================================
// 热通知级别枚举（对应 OSThermalNotificationLevel）
// 移植自 Battman thermal.h
// ============================================================================
typedef NS_ENUM(NSInteger, CPUthermalNotifLevel) {
    CPUthermalNotifLevelAny             = -1,
    CPUthermalNotifLevelNormal          = 0,
    CPUthermalNotifLevel70PercentTorch  = 1,
    CPUthermalNotifLevel70PercentBL     = 2,
    CPUthermalNotifLevel50PercentTorch  = 3,
    CPUthermalNotifLevel50PercentBL     = 4,
    CPUthermalNotifLevelDisableTorch    = 5,
    CPUthermalNotifLevel25PercentBL     = 6,
    CPUthermalNotifLevelDisableMapsHalo = 7,
    CPUthermalNotifLevelAppTerminate    = 8,
    CPUthermalNotifLevelDeviceRestart   = 9,
    CPUthermalNotifLevelReady           = 10,

    CPUthermalNotifLevelUnknown         = 999
};

// ============================================================================
// 系统通知名称
// ============================================================================
// kOSThermalNotificationPressureLevelName (系统导出符号)
// 实际值: "com.apple.system.thermalpressurelevel"
__OSX_AVAILABLE_STARTING(__MAC_10_10, __IPHONE_7_0)
extern const char *const kOSThermalNotificationPressureLevelName;

// ============================================================================
// 获取热压力字符串描述
// ============================================================================
static inline const char *CPUthermalPressureString(CPUthermalPressureLevel pressure) {
    switch (pressure) {
        case CPUthermalPressureLevelNominal:  return "Nominal";
        case CPUthermalPressureLevelLight:    return "Light";
        case CPUthermalPressureLevelModerate: return "Moderate";
        case CPUthermalPressureLevelHeavy:    return "Heavy";
        case CPUthermalPressureLevelTrapping: return "Trapping";
        case CPUthermalPressureLevelSleeping: return "Sleeping";
        default:                              return "Unknown";
    }
}

// ============================================================================
// 获取当前热压力级别
// 移植自 Battman thermal.c -> thermal_pressure()
// ============================================================================
static inline CPUthermalPressureLevel CPUthermalGetPressureLevel(void) {
    int token;
    uint64_t level;

    if (notify_register_check(kOSThermalNotificationPressureLevelName, &token)) {
        return CPUthermalPressureLevelError;
    }
    if (notify_get_state(token, &level)) {
        notify_cancel(token);
        return CPUthermalPressureLevelError;
    }
    notify_cancel(token);

    if (level == 0)
        return CPUthermalPressureLevelNominal;

    if (level < 10) {
        // macOS 风格 (1-4)
        switch (level) {
            case 1:  return CPUthermalPressureLevelModerate;
            case 2:  return CPUthermalPressureLevelHeavy;
            case 3:  return CPUthermalPressureLevelTrapping;
            case 4:  return CPUthermalPressureLevelSleeping;
            default: return CPUthermalPressureLevelUnknown;
        }
    } else {
        // iOS 风格 (10-50)
        switch (level) {
            case 10: return CPUthermalPressureLevelLight;
            case 20: return CPUthermalPressureLevelModerate;
            case 30: return CPUthermalPressureLevelHeavy;
            case 40: return CPUthermalPressureLevelTrapping;
            case 50: return CPUthermalPressureLevelSleeping;
            default: return CPUthermalPressureLevelUnknown;
        }
    }
}

// ============================================================================
// 强制设置热压力级别
// 移植自 Battman thermal.c -> set_thermal_pressure()
//
// 通过 notify_set_state + notify_post 直接修改系统热压力通知状态，
// 所有监听 kOSThermalNotificationPressureLevelName 的组件都会收到变化。
// ============================================================================
static inline int CPUthermalSetPressureLevel(CPUthermalPressureLevel pressure) {
    uint64_t level = 0;
    int token = 0;

    if (notify_register_check(kOSThermalNotificationPressureLevelName, &token))
        return -1; // 不支持

    // iOS 风格编码 (10, 20, 30, 40, 50)
    switch (pressure) {
        case CPUthermalPressureLevelLight:    level = 10; break;
        case CPUthermalPressureLevelModerate: level = 20; break;
        case CPUthermalPressureLevelHeavy:    level = 30; break;
        case CPUthermalPressureLevelTrapping: level = 40; break;
        case CPUthermalPressureLevelSleeping: level = 50; break;
        default:                              level = 0;  break; // Nominal
    }

    if (notify_set_state(token, level)) {
        notify_cancel(token);
        return 1; // 设置失败
    }

    // 发送通知让所有监听者收到变化
    if (notify_post(kOSThermalNotificationPressureLevelName)) {
        notify_cancel(token);
        return 2; // 设置成功但通知发送失败
    }

    notify_cancel(token);
    return 0;
}

// ============================================================================
// 强制热压力为 Nominal（一键调用）
// ============================================================================
static inline int CPUthermalForceNominalPressure(void) {
    return CPUthermalSetPressureLevel(CPUthermalPressureLevelNominal);
}

// ============================================================================
// 读取最大触发温度（thermalmonitord 设置的值）
// 移植自 Battman thermal.c -> thermal_max_trigger_temperature()
// 单位：摄氏度
// ============================================================================
static inline float CPUthermalGetMaxTriggerTemperature(void) {
    int token;
    uint64_t level;

    if (notify_register_check("com.apple.system.maxthermalsensorvalue", &token))
        return -1.0f;
    if (notify_get_state(token, &level)) {
        notify_cancel(token);
        return -1.0f;
    }
    notify_cancel(token);

    return (float)level / 100.0f;
}

// ============================================================================
// 读取阳光暴露状态
// 移植自 Battman thermal.c -> thermal_solar_state()
// 返回值: 0=无暴露, 1=车窗暴露, 2=直接阳光暴露
// ============================================================================
static inline int CPUthermalGetSolarState(void) {
    int token;
    uint64_t level;

    if (notify_register_check("com.apple.system.thermalsunlightstate", &token))
        return 0;
    if (notify_get_state(token, &level)) {
        notify_cancel(token);
        return 0;
    }
    notify_cancel(token);

    return (int)level;
}

// ============================================================================
// 热通知级别控制（通过 dlopen 调用私有 SPI）
// 移植自 Battman thermal.c
// ============================================================================

// 动态解析热通知函数
static inline void *CPUthermalLoadThermalNotificationLib(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/ThermalNotification.framework/ThermalNotification", RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            // 回退: 可能在 libSystem 中
            handle = dlopen("/usr/lib/libThermalNotification.dylib", RTLD_NOW | RTLD_LOCAL);
        }
    });
    return handle;
}

// 获取当前热通知级别
static inline int CPUthermalGetCurrentNotifLevel(void) {
    static int (*func)(void) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = CPUthermalLoadThermalNotificationLib();
        if (handle) {
            func = dlsym(handle, "OSThermalNotificationCurrentLevel");
        }
    });
    if (!func) return -1;
    return func();
}

// 获取指定行为的热通知级别
static inline int CPUthermalNotifLevelForBehavior(int behavior) {
    static int (*func)(int) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = CPUthermalLoadThermalNotificationLib();
        if (handle) {
            func = dlsym(handle, "_OSThermalNotificationLevelForBehavior");
        }
    });
    if (!func) return -1;
    return func(behavior);
}

// 设置指定行为的热通知级别
static inline void CPUthermalSetNotifLevelForBehavior(int level) {
    static void (*func)(int) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = CPUthermalLoadThermalNotificationLib();
        if (handle) {
            func = dlsym(handle, "_OSThermalNotificationSetLevelForBehavior");
        }
    });
    if (func) {
        func(level);
    }
}

// 获取当前通知级别对应的枚举值
static inline CPUthermalNotifLevel CPUthermalGetNotifLevel(void) {
    int rawLevel = CPUthermalGetCurrentNotifLevel();
    if (rawLevel < 0) return CPUthermalNotifLevelUnknown;

    // 查询所有已知行为对应的通知级别
    for (int i = 0; i < CPUthermalNotifLevelUnknown; i++) {
        if (CPUthermalNotifLevelForBehavior(i) == rawLevel)
            return (CPUthermalNotifLevel)i;
    }

    return CPUthermalNotifLevelUnknown;
}

// 强制热通知级别为 Normal
static inline void CPUthermalForceNormalNotifLevel(void) {
    // 通过 notify 直接设通知状态为 Normal (0)
    // kOSThermalNotificationName — 对应 "com.apple.system.thermalnotification"
    int token = 0;
    if (notify_register_check("com.apple.system.thermalnotification", &token) == 0) {
        notify_set_state(token, 0);  // Normal
        notify_post("com.apple.system.thermalnotification");
        notify_cancel(token);
    }
}

// ============================================================================
// 组合调用：同时强制压力 Nominal + 通知 Normal
// ============================================================================
static inline void CPUthermalForceNominalCombined(void) {
    CPUthermalForceNominalPressure();
    CPUthermalForceNormalNotifLevel();
}

// ============================================================================
// 热压力检查 & 日志（用于调试）
// ============================================================================
static inline void CPUthermalLogPressureStatus(void) {
    CPUthermalPressureLevel pressure = CPUthermalGetPressureLevel();
    float maxTemp = CPUthermalGetMaxTriggerTemperature();
    int solarState = CPUthermalGetSolarState();
    int notifLevel = CPUthermalGetCurrentNotifLevel();

    NSLog(@"[CPUthermalPressure] 压力=%s(%ld) 最高触发温度=%.1f°C 阳光暴露=%d 通知级别=%d",
          CPUthermalPressureString(pressure), (long)pressure,
          maxTemp, solarState, notifLevel);
}

#endif /* CPUTHERMAL_THERMAL_PRESSURE_H */
