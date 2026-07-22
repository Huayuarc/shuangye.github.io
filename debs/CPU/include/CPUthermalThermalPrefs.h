#ifndef CPUTHERMAL_THERMAL_PREFS_H
#define CPUTHERMAL_THERMAL_PREFS_H

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <CPUthermalPaths.h>

#if !defined(_SCPREFERENCES_H)
#define _SCPREFERENCES_H

enum {
    kSCStatusOK,
    kSCStatusFailed = 1001,
    kSCStatusStale  = 3005,
};

typedef const struct __SCPreferences *SCPreferencesRef;

__BEGIN_DECLS
SCPreferencesRef SCPreferencesCreate(CFAllocatorRef allocator, CFStringRef name, CFStringRef prefsID);
CFPropertyListRef SCPreferencesGetValue(SCPreferencesRef prefs, CFStringRef key);
Boolean SCPreferencesSetValue(SCPreferencesRef prefs, CFStringRef key, CFPropertyListRef value);
Boolean SCPreferencesRemoveValue(SCPreferencesRef prefs, CFStringRef key);
void SCPreferencesSynchronize(SCPreferencesRef prefs);
Boolean SCPreferencesApplyChanges(SCPreferencesRef prefs);
Boolean SCPreferencesCommitChanges(SCPreferencesRef prefs);
int SCError(void);
const char *SCErrorString(int status);
__END_DECLS

#endif

static inline CFStringRef CPUthermalCreateCFString(const char *string) {
    return string ? CFStringCreateWithCString(kCFAllocatorDefault, string, kCFStringEncodingUTF8) : NULL;
}

static inline SCPreferencesRef CPUthermalCreateOSThermalPrefs(void) {
    CFStringRef name = CPUthermalCreateCFString("CPUthermal");
    CFStringRef prefsID = CPUthermalCreateCFString("OSThermalStatus.plist");
    SCPreferencesRef prefs = SCPreferencesCreate(kCFAllocatorDefault, name, prefsID);
    if (name) CFRelease(name);
    if (prefsID) CFRelease(prefsID);
    return prefs;
}

static inline int CPUthermalSaveOSThermalPrefs(SCPreferencesRef prefs) {
    if (!prefs) return kSCStatusFailed;
    if (!SCPreferencesCommitChanges(prefs)) {
        int status = SCError();
        return status == kSCStatusOK ? kSCStatusFailed : status;
    }
    SCPreferencesApplyChanges(prefs);
    SCPreferencesSynchronize(prefs);
    return kSCStatusOK;
}

static inline BOOL CPUthermalSetOSThermalBool(SCPreferencesRef prefs, const char *key, BOOL enabled) {
    if (!prefs || !key) return NO;
    CFStringRef cfKey = CPUthermalCreateCFString(key);
    if (!cfKey) return NO;
    BOOL ok = SCPreferencesSetValue(prefs, cfKey, enabled ? kCFBooleanTrue : kCFBooleanFalse);
    CFRelease(cfKey);
    return ok;
}

static inline BOOL CPUthermalSetOSThermalInt(SCPreferencesRef prefs, const char *key, int value) {
    if (!prefs || !key) return NO;
    CFStringRef cfKey = CPUthermalCreateCFString(key);
    if (!cfKey) return NO;
    CFNumberRef cfValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    if (!cfValue) {
        CFRelease(cfKey);
        return NO;
    }
    BOOL ok = SCPreferencesSetValue(prefs, cfKey, cfValue);
    CFRelease(cfValue);
    CFRelease(cfKey);
    return ok;
}

static inline void CPUthermalRemoveOSThermalKey(SCPreferencesRef prefs, const char *key) {
    if (!prefs || !key) return;
    CFStringRef cfKey = CPUthermalCreateCFString(key);
    if (!cfKey) return;
    SCPreferencesRemoveValue(prefs, cfKey);
    CFRelease(cfKey);
}

static inline int CPUthermalApplyManagedThermalStatusOverrides(BOOL manageSunlightExposure,
                                                              BOOL lockSunlightExposure,
                                                              BOOL manageLowBatterySimulation,
                                                              BOOL simulateLowBattery) {
    if (!manageSunlightExposure && !manageLowBatterySimulation) return kSCStatusOK;

    SCPreferencesRef prefs = CPUthermalCreateOSThermalPrefs();
    if (!prefs) return kSCStatusFailed;

    BOOL ok = YES;
    if (manageSunlightExposure) {
        if (lockSunlightExposure) {
            ok = CPUthermalSetOSThermalBool(prefs, "sunlightOverride", YES) && ok;
            ok = CPUthermalSetOSThermalBool(prefs, "sunlightOverridePersistentlyEnabled", YES) && ok;
        } else {
            CPUthermalRemoveOSThermalKey(prefs, "sunlightOverride");
            CPUthermalRemoveOSThermalKey(prefs, "sunlightOverridePersistentlyEnabled");
        }
    }

    if (manageLowBatterySimulation) {
        if (simulateLowBattery) {
            int simulatedSOC = kCPUthermalLowBatterySimulationSOCPct;
            ok = CPUthermalSetOSThermalInt(prefs, "kBatteryPercentRemainingKey", simulatedSOC) && ok;
            ok = CPUthermalSetOSThermalInt(prefs, "kBatteryRawGasGaugeSOCKey", simulatedSOC) && ok;
            ok = CPUthermalSetOSThermalInt(prefs, "kBatteryChemSOCKey", simulatedSOC) && ok;
            ok = CPUthermalSetOSThermalBool(prefs, "kBatteryPercentRemainingKeyPersistentlyEnabled", YES) && ok;
            ok = CPUthermalSetOSThermalBool(prefs, "kBatteryRawGasGaugeSOCKeyPersistentlyEnabled", YES) && ok;
            ok = CPUthermalSetOSThermalBool(prefs, "kBatteryChemSOCKeyPersistentlyEnabled", YES) && ok;
            ok = CPUthermalSetOSThermalBool(prefs, "kOnChargerStatusKey", NO) && ok;
            ok = CPUthermalSetOSThermalBool(prefs, "kOnChargerStatusKeyPersistentlyEnabled", YES) && ok;
        } else {
            CPUthermalRemoveOSThermalKey(prefs, "kBatteryPercentRemainingKey");
            CPUthermalRemoveOSThermalKey(prefs, "kBatteryRawGasGaugeSOCKey");
            CPUthermalRemoveOSThermalKey(prefs, "kBatteryChemSOCKey");
            CPUthermalRemoveOSThermalKey(prefs, "kBatteryPercentRemainingKeyPersistentlyEnabled");
            CPUthermalRemoveOSThermalKey(prefs, "kBatteryRawGasGaugeSOCKeyPersistentlyEnabled");
            CPUthermalRemoveOSThermalKey(prefs, "kBatteryChemSOCKeyPersistentlyEnabled");
            CPUthermalRemoveOSThermalKey(prefs, "kOnChargerStatusKey");
            CPUthermalRemoveOSThermalKey(prefs, "kOnChargerStatusKeyPersistentlyEnabled");
        }
    }

    int result = ok ? CPUthermalSaveOSThermalPrefs(prefs) : kSCStatusFailed;
    CFRelease(prefs);
    return result;
}

static inline BOOL CPUthermalPrefsContainKey(NSDictionary *prefs, const char *key) {
    if (!prefs || !key) return NO;
    return [prefs objectForKey:S(key)] != nil;
}

static inline BOOL CPUthermalBoolPref(NSDictionary *prefs, const char *key, BOOL defaultValue) {
    if (!prefs || !key) return defaultValue;
    id value = [prefs objectForKey:S(key)];
    return value ? [value boolValue] : defaultValue;
}

static inline int CPUthermalApplyThermalStatusOverridesFromPrefs(NSDictionary *prefs) {
    BOOL enabled = CPUthermalBoolPref(prefs, "enabled", NO);
    BOOL cpuProtection = CPUthermalBoolPref(prefs, "cpuProtection", YES);
    NSString *powerMode = prefs ? [prefs objectForKey:S("powerMode")] : nil;
    BOOL manageSunlightExposure = CPUthermalPrefsContainKey(prefs, kCPUthermalLockSunlightExposureKeyC);
    BOOL manageLowBatterySimulation = YES;
    BOOL lockSunlightExposure = enabled && CPUthermalBoolPref(prefs, kCPUthermalLockSunlightExposureKeyC, NO);
    BOOL simulateLowBattery = enabled && cpuProtection && [powerMode isKindOfClass:[NSString class]] && [powerMode isEqualToString:S(kCPUthermalLowPowerModeC)];

    return CPUthermalApplyManagedThermalStatusOverrides(manageSunlightExposure,
                                                       lockSunlightExposure,
                                                       manageLowBatterySimulation,
                                                       simulateLowBattery);
}

// ============================================================================
// 温控监控偏好键名 (温控等级: 热压/通知/重置)
// ============================================================================

/// 温控压力监控开关 (BOOL): 在 thermalmonitord 中周期性读取并记录热压
static const char *const kCPUthermalPressureMonitorKeyC = "pressureMonitor";

/// 通知级别监控开关 (BOOL): 跟踪系统热通知级别变化
static const char *const kCPUthermalNotificationMonitorKeyC = "notificationMonitor";

/// 重置热通知 (BOOL): 设置为 YES 时触发一次通知级别重置
static const char *const kCPUthermalResetNotifKeyC = "resetThermalNotifications";

/// 热压覆盖值 (NSString): "nominal"/"light"/"moderate"/"heavy"/"trapping"/"sleeping"
/// 设置后 thermalmonitord 会调用 CPUthermalSetPressure 覆盖系统热压
static const char *const kCPUthermalPressureOverrideKeyC = "thermalPressureOverride";

/// 热压覆盖开关 (BOOL): 启用后才应用热压覆盖值
static const char *const kCPUthermalPressureOverrideEnabledKeyC = "pressureOverrideEnabled";

/// 通知: 温控监控状态变更
static const char *const kCPUthermalMonitorNotifC = "com.huayuarc.CPUthermal/thermalMonitorChanged";

#endif
