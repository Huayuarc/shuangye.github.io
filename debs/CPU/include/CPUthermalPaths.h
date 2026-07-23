#ifndef CPUTHERMAL_PATHS_H
#define CPUTHERMAL_PATHS_H

#import <Foundation/Foundation.h>
#include <roothide.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <dlfcn.h>
#include <os/base.h>
#include <pthread.h>

#define S(str) [NSString stringWithUTF8String:(str)]

static const char *kCPUthermalPrefRootFSPathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kCPUthermalOldJBPrefRelativePathC = "Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kCPUthermalSettingsChangedNotifC = "com.huayuarc.CPUthermal/settingsChanged";
static const char *kCPUthermalPowerModeChangedNotifC = "com.huayuarc.CPUthermal/powerModeChanged";
static const NSInteger kCPUthermalDefaultMaxPCoreFrequencyMHz = 3240;

// ============================================================================
// 温控等级调校 — 从 Battman Thermal Tunes 完整移植
// ============================================================================
#pragma mark - Thermal Level Control

// 偏好键
static const char *kCPUthermalThermalLevelControlEnabledC = "thermalLevelControlEnabled";
static const char *kCPUthermalManualThermalPressureC      = "manualThermalPressure";
static const char *kCPUthermalManualThermalNotifLevelC     = "manualThermalNotifLevel";

// CPU 功率值（從 insulation 移植：用於 backlightComponentControl 的 maxThermalPower/minThermalPower）
static const char *kCPUthermalCPUMinPowerValueC = "cpuMinPowerValue";

// 热压力级别枚举（与 Battman 一致）
typedef enum {
    kBattmanThermalPressureLevelError = -1,
    kBattmanThermalPressureLevelNominal,    // 0 正常
    kBattmanThermalPressureLevelLight,      // 1 轻微
    kBattmanThermalPressureLevelModerate,   // 2 中等
    kBattmanThermalPressureLevelHeavy,      // 3 严重
    kBattmanThermalPressureLevelTrapping,   // 4 临界
    kBattmanThermalPressureLevelSleeping,   // 5 休眠
    kBattmanThermalPressureLevelUnknown     // 6 未知
} CPUthermalThermalPressure;

// 热通知级别枚举（与 Battman 一致）
typedef enum {
    kBattmanThermalNotificationLevelAny = -1,
    kBattmanThermalNotificationLevelNormal,               // 0
    kBattmanThermalNotificationLevel70PercentTorch,        // 1
    kBattmanThermalNotificationLevel70PercentBacklight,    // 2
    kBattmanThermalNotificationLevel50PercentTorch,        // 3
    kBattmanThermalNotificationLevel50PercentBacklight,    // 4
    kBattmanThermalNotificationLevelDisableTorch,          // 5
    kBattmanThermalNotificationLevel25PercentBacklight,    // 6
    kBattmanThermalNotificationLevelDisableMapsHalo,       // 7
    kBattmanThermalNotificationLevelAppTerminate,          // 8
    kBattmanThermalNotificationLevelDeviceRestart,         // 9
    kBattmanThermalNotificationLevelThermalTableReady,     // 10
    kBattmanThermalNotificationLevelUnknown                // 11
} CPUthermalThermalNotifLevel;

static const char *CPUthermalPressureDisplayNames[] = {
    "正常 (Nominal)",
    "轻微 (Light)",
    "中等 (Moderate)",
    "严重 (Heavy)",
    "临界 (Trapping)",
    "休眠 (Sleeping)"
};

static const char *CPUthermalNotifLevelDisplayNames[] = {
    "正常 (Normal)",
    "70% 闪光灯",
    "70% 背光",
    "50% 闪光灯",
    "50% 背光",
    "禁用闪光灯",
    "25% 背光",
    "禁用 Maps 光晕",
    "终止应用",
    "重启设备",
    "热表就绪"
};

// 热压力级别字符串（用于 notify API）
static const char *CPUthermalPressureLevelStrings[] = {
    "nominal",
    "light",
    "moderate",
    "heavy",
    "trapping",
    "sleeping"
};

#pragma mark - 热等级 notify API 辅助函数

// 缓存 token，避免每次设置时重复注册
static int g_thermalPressureToken = 0;
static int g_thermalNotifToken = 0;
static dispatch_once_t g_thermalTokensOnce;
static pthread_key_t g_notifyWriteKey;
static dispatch_once_t g_notifyKeyOnce;

// 线程特定的 notify_set_state 守卫标志
// 使用 pthread_key 确保跨多线程正确性
// 当 CPUthermalSetThermalPressure 设置值时，本线程标志为 YES
// Tweak.xm 的 notify_set_state hook 检查此标志放行自己的写入
static inline void ensureNotifyWriteKey(void) {
    dispatch_once(&g_notifyKeyOnce, ^{
        pthread_key_create(&g_notifyWriteKey, NULL);
    });
}

static inline BOOL getOwnNotifyWrite(void) {
    ensureNotifyWriteKey();
    return (BOOL)(uintptr_t)pthread_getspecific(g_notifyWriteKey);
}

static inline void setOwnNotifyWrite(BOOL val) {
    ensureNotifyWriteKey();
    pthread_setspecific(g_notifyWriteKey, (void *)(uintptr_t)val);
}

static inline void CPUthermalEnsureThermalTokens(void) {
    dispatch_once(&g_thermalTokensOnce, ^{
        notify_register_check("com.apple.system.thermalpressure.level", &g_thermalPressureToken);
        notify_register_check("com.apple.system.thermalnotification", &g_thermalNotifToken);
    });
}

// 热压力级别 notify state 映射 (com.apple.system.thermalpressure.level)
// iOS 16 使用 0=正常, 10/20/30/40/50 作为热压力级别状态值
static inline uint64_t CPUthermalPressureLevelToNotifyState(CPUthermalThermalPressure pressure) {
    switch (pressure) {
        case kBattmanThermalPressureLevelLight:     return 10;
        case kBattmanThermalPressureLevelModerate:  return 20;
        case kBattmanThermalPressureLevelHeavy:     return 30;
        case kBattmanThermalPressureLevelTrapping:  return 40;
        case kBattmanThermalPressureLevelSleeping:  return 50;
        default:                                    return 0;
    }
}

static inline CPUthermalThermalPressure CPUthermalReadThermalPressure(void) {
    CPUthermalEnsureThermalTokens();

    uint64_t level = 0;
    if (notify_get_state(g_thermalPressureToken, &level) != 0)
        return kBattmanThermalPressureLevelError;

    // OSThermalPressureLevel 映射
    switch (level) {
        case 0:  return kBattmanThermalPressureLevelNominal;
        case 1:  return kBattmanThermalPressureLevelModerate;
        case 2:  return kBattmanThermalPressureLevelHeavy;
        case 3:  return kBattmanThermalPressureLevelTrapping;
        case 4:  return kBattmanThermalPressureLevelSleeping;
        case 10: return kBattmanThermalPressureLevelLight;
        case 20: return kBattmanThermalPressureLevelModerate;
        case 30: return kBattmanThermalPressureLevelHeavy;
        case 40: return kBattmanThermalPressureLevelTrapping;
        case 50: return kBattmanThermalPressureLevelSleeping;
        default: return kBattmanThermalPressureLevelUnknown;
    }
}

static inline int CPUthermalSetThermalPressure(CPUthermalThermalPressure pressure) {
    CPUthermalEnsureThermalTokens();

    uint64_t level = CPUthermalPressureLevelToNotifyState(pressure);

    // 设置线程特定的守卫标志，使 Tweak.xm 的 notify_set_state hook 放行此次写入
    setOwnNotifyWrite(YES);

    // 设置主热压力级别 — notify state（用户态可见）
    int ret = notify_set_state(g_thermalPressureToken, level);
    setOwnNotifyWrite(NO);
    if (ret != 0)
        return 1;

    // 同时广播到 pearl pressure（热管理子系统也会监听此 key）
    int pearlToken = 0;
    if (notify_register_check("com.apple.system.thermalpressure.pearl.pressure", &pearlToken) == 0) {
        setOwnNotifyWrite(YES);
        notify_set_state(pearlToken, level);
        setOwnNotifyWrite(NO);
        notify_post("com.apple.system.thermalpressure.pearl.pressure");
        notify_cancel(pearlToken);
    }

    // 发布主通知唤醒监听者
    notify_post("com.apple.system.thermalpressure.level");
    return 0;
}

// ---- Battman 完整版 _OSThermalNotification 函数 ----
// 通过 dlsym 运行时加载私有框架函数

// ============================ 安全 dlsym 包装 ============================
// 私有框架函数在 thermalmonitord 进程中可能不可用
// 使用安全的 dlsym + dispatch_once + NULL 检查，避免空指针崩溃
// =========================================================================

static inline int (*CPUthermalSafeOSThermalNotificationCurrentLevel(void))(void) {
    static int (*fp)(void) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fp = (int(*)(void))dlsym(RTLD_DEFAULT, "OSThermalNotificationCurrentLevel");
    });
    return fp;
}

static inline int (*CPUthermalSafeOSThermalNotificationLevelForBehavior(void))(int) {
    static int (*fp)(int) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fp = (int(*)(int))dlsym(RTLD_DEFAULT, "_OSThermalNotificationLevelForBehavior");
    });
    return fp;
}

static inline void (*CPUthermalSafeOSThermalNotificationSetLevelForBehavior(void))(int) {
    static void (*fp)(int) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fp = (void(*)(int))dlsym(RTLD_DEFAULT, "_OSThermalNotificationSetLevelForBehavior");
    });
    return fp;
}

static inline CPUthermalThermalNotifLevel CPUthermalReadThermalNotifLevel(void) {
    CPUthermalEnsureThermalTokens();

    // 优先使用私有框架函数 OSThermalNotificationCurrentLevel
    // 它返回的是系统实际使用的热通知级别值
    int (*currentLevel)(void) = CPUthermalSafeOSThermalNotificationCurrentLevel();
    if (currentLevel) {
        int rawLevel = currentLevel();
        if (rawLevel < 0)
            return kBattmanThermalNotificationLevelAny;

        // 尝试通过 behavior 映射
        int (*levelForBehavior)(int) = CPUthermalSafeOSThermalNotificationLevelForBehavior();
        if (levelForBehavior) {
            for (int i = 0; i < kBattmanThermalNotificationLevelUnknown; i++) {
                int behaviorLevel = levelForBehavior(i);
                if (behaviorLevel == rawLevel)
                    return (CPUthermalThermalNotifLevel)i;
            }
        }
        return kBattmanThermalNotificationLevelUnknown;
    }

    // 降级: 使用 notify_get_state 读取
    uint64_t state = 0;
    if (notify_get_state(g_thermalNotifToken, &state) == 0) {
        if (state > kBattmanThermalNotificationLevelAny &&
            state < kBattmanThermalNotificationLevelUnknown)
            return (CPUthermalThermalNotifLevel)state;
    }
    return kBattmanThermalNotificationLevelAny;
}

static inline int CPUthermalSetThermalNotifLevel(CPUthermalThermalNotifLevel level) {
    CPUthermalEnsureThermalTokens();

    // 方法1: 尝试使用 _OSThermalNotificationSetLevelForBehavior (可能不可用)
    void (*setLevel)(int) = CPUthermalSafeOSThermalNotificationSetLevelForBehavior();
    if (setLevel) {
        setLevel((int)level);
    }

    // 方法2: 通过 notify_set_state 设置 (与 Battman 原始实现一致)
    setOwnNotifyWrite(YES);
    int ret = notify_set_state(g_thermalNotifToken, (uint64_t)level);
    setOwnNotifyWrite(NO);
    if (ret != 0)
        return 1;

    notify_post("com.apple.system.thermalnotification");
    return 0;
}

// 读取最高传感器温度（从 Battman 移植）
static inline float CPUthermalReadMaxTriggerTemperature(void) {
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

    return (float)level / 100.0f;
}

// 读取阳光暴晒状态（从 Battman 移植）
static inline int CPUthermalReadSolarState(void) {
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

// ---- 显示辅助函数 ----

static inline NSString *CPUthermalPressureDisplayString(CPUthermalThermalPressure pressure) {
    if (pressure < kBattmanThermalPressureLevelNominal || pressure >= kBattmanThermalPressureLevelUnknown)
        return S("未知");
    return S(CPUthermalPressureDisplayNames[pressure]);
}

static inline NSString *CPUthermalNotifLevelDisplayString(CPUthermalThermalNotifLevel level) {
    if (level <= kBattmanThermalNotificationLevelAny || level >= kBattmanThermalNotificationLevelUnknown)
        return S("未知");
    return S(CPUthermalNotifLevelDisplayNames[level]);
}

static inline NSString *CPUthermalStringFromCPath(const char *path) {
    return path ? [NSString stringWithUTF8String:path] : nil;
}

static inline NSString *CPUthermalHardwareIdentifier(void) {
    char machine[256] = {0};
    size_t size = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0 && machine[0] != '\0') {
        return S(machine);
    }
    return S("");
}

static inline NSInteger CPUthermalNativeMaxPCoreFrequencyMHzForHardware(NSString *hardware) {
    if (hardware.length == 0) {
        return 0;
    }

    if ([hardware isEqualToString:S("iPhone12,1")] ||
        [hardware isEqualToString:S("iPhone12,3")] ||
        [hardware isEqualToString:S("iPhone12,5")]) {
        return 2650;
    }
    if ([hardware isEqualToString:S("iPhone13,1")] ||
        [hardware isEqualToString:S("iPhone13,2")] ||
        [hardware isEqualToString:S("iPhone13,3")] ||
        [hardware isEqualToString:S("iPhone13,4")]) {
        return 3090;
    }
    if ([hardware isEqualToString:S("iPhone14,2")] ||
        [hardware isEqualToString:S("iPhone14,3")] ||
        [hardware isEqualToString:S("iPhone14,4")] ||
        [hardware isEqualToString:S("iPhone14,5")] ||
        [hardware isEqualToString:S("iPhone14,7")] ||
        [hardware isEqualToString:S("iPhone14,8")]) {
        return 3230;
    }
    if ([hardware isEqualToString:S("iPhone15,2")] ||
        [hardware isEqualToString:S("iPhone15,3")] ||
        [hardware isEqualToString:S("iPhone15,4")] ||
        [hardware isEqualToString:S("iPhone15,5")]) {
        return 3460;
    }
    if ([hardware isEqualToString:S("iPhone16,1")] ||
        [hardware isEqualToString:S("iPhone16,2")]) {
        return 3780;
    }

    return 0;
}

static inline NSInteger CPUthermalNativeMaxPCoreFrequencyMHz(void) {
    NSInteger frequency = CPUthermalNativeMaxPCoreFrequencyMHzForHardware(CPUthermalHardwareIdentifier());
    return frequency > 0 ? frequency : kCPUthermalDefaultMaxPCoreFrequencyMHz;
}

static inline NSString *CPUthermalJBRootPathForRootFSPath(const char *path) {
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE) || defined(THEOS_PACKAGE_INSTALL_PREFIX)
    return CPUthermalStringFromCPath(jbroot(path));
#else
    return CPUthermalStringFromCPath(path);
#endif
}

static inline NSString *CPUthermalCurrentPrefPath(void) {
    return CPUthermalJBRootPathForRootFSPath(kCPUthermalPrefRootFSPathC);
}

static inline NSString *CPUthermalOldJBRootPrefPath(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *resolvedJBRoot = [fileManager destinationOfSymbolicLinkAtPath:S("/var/jb") error:nil];
    if (resolvedJBRoot.length > 0) {
        return [resolvedJBRoot stringByAppendingPathComponent:S(kCPUthermalOldJBPrefRelativePathC)];
    }
    return [S("/var/jb") stringByAppendingPathComponent:S(kCPUthermalOldJBPrefRelativePathC)];
}

static inline NSArray<NSString *> *CPUthermalLegacyPrefPaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *oldJBPath = CPUthermalOldJBRootPrefPath();
    if (oldJBPath.length > 0) {
        [paths addObject:oldJBPath];
    }
    NSString *rootFSPath = CPUthermalStringFromCPath(kCPUthermalPrefRootFSPathC);
    if (rootFSPath.length > 0 && ![paths containsObject:rootFSPath]) {
        [paths addObject:rootFSPath];
    }
    return paths;
}

static inline NSString *CPUthermalExistingExecutablePath(const char *rootFSPath, NSArray<NSString *> *fallbackPaths) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *resolvedPath = CPUthermalJBRootPathForRootFSPath(rootFSPath);
    if (resolvedPath.length > 0 && [fileManager isExecutableFileAtPath:resolvedPath]) {
        return resolvedPath;
    }

    for (NSString *path in fallbackPaths) {
        if (path.length > 0 && [fileManager isExecutableFileAtPath:path]) {
            return path;
        }
    }

    return resolvedPath;
}

static inline NSString *CPUthermalLaunchctlPath(void) {
    return CPUthermalExistingExecutablePath("/usr/bin/launchctl", @[
        S("/var/jb/usr/bin/launchctl"),
        S("/var/jb/bin/launchctl"),
        S("/usr/bin/launchctl"),
        S("/bin/launchctl")
    ]);
}

static inline NSString *CPUthermalKillallPath(void) {
    return CPUthermalExistingExecutablePath("/usr/bin/killall", @[
        S("/var/jb/usr/bin/killall"),
        S("/var/jb/bin/killall"),
        S("/usr/bin/killall"),
        S("/bin/killall")
    ]);
}

static inline NSString *CPUthermalSBReloadPath(void) {
    return CPUthermalExistingExecutablePath("/usr/bin/sbreload", @[
        S("/var/jb/usr/bin/sbreload"),
        S("/var/jb/bin/sbreload"),
        S("/usr/bin/sbreload")
    ]);
}

static inline NSString *CPUthermalToolPath(void) {
    return CPUthermalExistingExecutablePath("/usr/local/bin/CPUthermalTool", @[
        S("/var/jb/usr/local/bin/CPUthermalTool"),
        S("/usr/local/bin/CPUthermalTool")
    ]);
}

static inline void CPUthermalSpawnDetached(NSString *path, char *const args[]) {
    if (path.length == 0) {
        return;
    }

    pid_t pid = 0;
    if (posix_spawn(&pid, [path fileSystemRepresentation], NULL, NULL, args, NULL) == 0) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            waitpid(pid, NULL, 0);
        });
    }
}

static inline BOOL CPUthermalRunAndWait(NSString *path, char *const args[]) {
    if (path.length == 0) {
        return NO;
    }

    pid_t pid = 0;
    if (posix_spawn(&pid, [path fileSystemRepresentation], NULL, NULL, args, NULL) != 0) {
        return NO;
    }
    waitpid(pid, NULL, 0);
    return YES;
}

static inline void CPUthermalRestartThermalmonitordNow(void) {
    NSString *toolPath = CPUthermalToolPath();
    if (toolPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
        char *args[] = {(char *)"CPUthermalTool", (char *)"restart-thermalmonitord", NULL};
        if (CPUthermalRunAndWait(toolPath, args)) {
            return;
        }
    }

    NSString *killallPath = CPUthermalKillallPath();
    if (killallPath.length > 0) {
        char *args[] = {(char *)"killall", (char *)"-q", (char *)"thermalmonitord", NULL};
        CPUthermalRunAndWait(killallPath, args);
    }
}

static inline void CPUthermalRestartThermalmonitordSoon(void) {
    NSString *toolPath = CPUthermalToolPath();
    if (toolPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
        char *args[] = {(char *)"CPUthermalTool", (char *)"restart-thermalmonitord-delayed", NULL};
        CPUthermalSpawnDetached(toolPath, args);
        return;
    }

    NSString *killallPath = CPUthermalKillallPath();
    if (killallPath.length > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CPUthermalRestartThermalmonitordNow();
        });
    }
}

static inline void CPUthermalEnsurePrefDirectory(void) {
    NSString *path = CPUthermalCurrentPrefPath();
    NSString *directory = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

static inline NSMutableDictionary *CPUthermalReadMutablePrefs(void) {
    NSString *path = CPUthermalCurrentPrefPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (prefs) {
        return prefs;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *legacyPath in CPUthermalLegacyPrefPaths()) {
        if ([legacyPath isEqualToString:path]) {
            continue;
        }
        NSDictionary *legacyPrefs = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
        if (!legacyPrefs) {
            continue;
        }

        prefs = [legacyPrefs mutableCopy];
        CPUthermalEnsurePrefDirectory();
        if ([prefs writeToFile:path atomically:YES]) {
            [fileManager removeItemAtPath:legacyPath error:nil];
        }
        return prefs;
    }

    return nil;
}

static inline NSDictionary *CPUthermalReadPrefs(void) {
    return CPUthermalReadMutablePrefs();
}

// 從偏好讀取 CPU 最大功率值（從 insulation 移植）
// 用於 backlightComponentControl 的 maxThermalPower/minThermalPower
// 用戶可在設定頁面輸入數字值
static inline int CPUthermalReadCPUMaxPower(void) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    if (!prefs) return 0;
    NSString *valueStr = [prefs objectForKey:S(kCPUthermalCPUMinPowerValueC)];
    if (!valueStr || ![valueStr isKindOfClass:[NSString class]]) return 0;
    int value = [valueStr intValue];
    return value > 0 ? value : 0;
}

static inline BOOL CPUthermalWritePrefs(NSDictionary *prefs) {
    if (!prefs) {
        return NO;
    }

    NSString *path = CPUthermalCurrentPrefPath();
    CPUthermalEnsurePrefDirectory();
    BOOL ok = [prefs writeToFile:path atomically:YES];
    if (ok) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSString *legacyPath in CPUthermalLegacyPrefPaths()) {
            if (![legacyPath isEqualToString:path]) {
                [fileManager removeItemAtPath:legacyPath error:nil];
            }
        }
    }
    return ok;
}

#endif
