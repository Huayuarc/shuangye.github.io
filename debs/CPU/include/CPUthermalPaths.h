#ifndef CPUTHERMAL_PATHS_H
#define CPUTHERMAL_PATHS_H

#import <Foundation/Foundation.h>
#include <roothide.h>
#include <dispatch/dispatch.h>
#include <spawn.h>
#include <limits.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <notify.h>

#define S(str) [NSString stringWithUTF8String:(str)]

static const char *kCPUthermalPrefRootFSPathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kCPUthermalOldJBPrefRelativePathC = "Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kCPUthermalSettingsChangedNotifC = "com.huayuarc.CPUthermal/settingsChanged";
static const char *kCPUthermalPowerModeChangedNotifC = "com.huayuarc.CPUthermal/powerModeChanged";
static const char *kCPUthermalThermalPressureChangedNotifC = "com.huayuarc.CPUthermal/thermalPressureChanged";
static const char *kCPUthermalThermalPressureNotifyBypassC = "com.huayuarc.CPUthermal/thermalPressureNotifyBypass";
static const char *kCPUthermalThermalPressureKeyC = "thermalPressureLevel";
static const char *kCPUthermalThermalNotificationKeyC = "thermalNotificationLevel";
static const char *kCPUthermalThermalNotificationNotifyBypassC = "com.huayuarc.CPUthermal/thermalNotificationNotifyBypass";
static const NSInteger kCPUthermalDefaultMaxPCoreFrequencyMHz = 3240;

static inline NSDictionary *CPUthermalReadPrefs(void);
static inline NSString *CPUthermalToolPath(void);
static inline BOOL CPUthermalRunAndWait(NSString *path, char *const args[]);

typedef enum {
    kCPUthermalThermalPressureLevelError = -1,
    kCPUthermalThermalPressureLevelNominal,
    kCPUthermalThermalPressureLevelLight,
    kCPUthermalThermalPressureLevelModerate,
    kCPUthermalThermalPressureLevelHeavy,
    kCPUthermalThermalPressureLevelTrapping,
    kCPUthermalThermalPressureLevelSleeping,

    kCPUthermalThermalPressureLevelUnknown
} CPUthermalThermalPressureLevel;

typedef enum {
    kCPUthermalThermalNotificationLevelAny = -1,
    kCPUthermalThermalNotificationLevelNormal,
    kCPUthermalThermalNotificationLevel70PercentTorch,
    kCPUthermalThermalNotificationLevel70PercentBacklight,
    kCPUthermalThermalNotificationLevel50PercentTorch,
    kCPUthermalThermalNotificationLevel50PercentBacklight,
    kCPUthermalThermalNotificationLevelDisableTorch,
    kCPUthermalThermalNotificationLevel25PercentBacklight,
    kCPUthermalThermalNotificationLevelDisableMapsHalo,
    kCPUthermalThermalNotificationLevelAppTerminate,
    kCPUthermalThermalNotificationLevelDeviceRestart,
    kCPUthermalThermalNotificationLevelThermalTableReady,

    kCPUthermalThermalNotificationLevelUnknown
} CPUthermalThermalNotificationLevel;

__attribute__((weak_import)) extern const char *const kOSThermalNotificationPressureLevelName;
__attribute__((weak_import)) extern const char *const kOSThermalNotificationName;
__attribute__((weak_import)) int OSThermalNotificationCurrentLevel(void);
__attribute__((weak_import)) int _OSThermalNotificationLevelForBehavior(int behavior);

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

    // 型号.txt: hardwareModel -> 性能大核最高主频(MHz)
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

static inline const char *CPUthermalOSThermalPressureNotificationName(void) {
    if (&kOSThermalNotificationPressureLevelName != NULL && kOSThermalNotificationPressureLevelName != NULL) {
        return kOSThermalNotificationPressureLevelName;
    }
    return "com.apple.system.thermalpressurelevel";
}

static inline const char *CPUthermalOSThermalNotificationName(void) {
    if (&kOSThermalNotificationName != NULL && kOSThermalNotificationName != NULL) {
        return kOSThermalNotificationName;
    }
    return NULL;
}

static inline NSString *CPUthermalThermalPressureTitle(CPUthermalThermalPressureLevel pressure) {
    switch (pressure) {
        case kCPUthermalThermalPressureLevelNominal:
            return S("正常");
        case kCPUthermalThermalPressureLevelLight:
            return S("轻微");
        case kCPUthermalThermalPressureLevelModerate:
            return S("中等");
        case kCPUthermalThermalPressureLevelHeavy:
            return S("严重");
        case kCPUthermalThermalPressureLevelTrapping:
            return S("锁定");
        case kCPUthermalThermalPressureLevelSleeping:
            return S("睡眠");
        case kCPUthermalThermalPressureLevelError:
            return S("不可用");
        case kCPUthermalThermalPressureLevelUnknown:
        default:
            return S("未知");
    }
}

static inline uint64_t CPUthermalRawOSThermalPressureLevel(CPUthermalThermalPressureLevel pressure) {
    switch (pressure) {
        case kCPUthermalThermalPressureLevelLight:
            return 10;
        case kCPUthermalThermalPressureLevelModerate:
            return 20;
        case kCPUthermalThermalPressureLevelHeavy:
            return 30;
        case kCPUthermalThermalPressureLevelTrapping:
            return 40;
        case kCPUthermalThermalPressureLevelSleeping:
            return 50;
        case kCPUthermalThermalPressureLevelNominal:
        default:
            return 0;
    }
}

static inline CPUthermalThermalPressureLevel CPUthermalPressureLevelFromRawOSThermalValue(uint64_t level) {
    if (level == 0) {
        return kCPUthermalThermalPressureLevelNominal;
    }

    if (level < 10) {
        switch (level) {
            case 1:
                return kCPUthermalThermalPressureLevelModerate;
            case 2:
                return kCPUthermalThermalPressureLevelHeavy;
            case 3:
                return kCPUthermalThermalPressureLevelTrapping;
            case 4:
                return kCPUthermalThermalPressureLevelSleeping;
            default:
                return kCPUthermalThermalPressureLevelUnknown;
        }
    }

    switch (level) {
        case 10:
            return kCPUthermalThermalPressureLevelLight;
        case 20:
            return kCPUthermalThermalPressureLevelModerate;
        case 30:
            return kCPUthermalThermalPressureLevelHeavy;
        case 40:
            return kCPUthermalThermalPressureLevelTrapping;
        case 50:
            return kCPUthermalThermalPressureLevelSleeping;
        default:
            return kCPUthermalThermalPressureLevelUnknown;
    }
}

static inline CPUthermalThermalPressureLevel CPUthermalCurrentThermalPressureLevel(void) {
    int token = 0;
    uint64_t level = 0;
    const char *name = CPUthermalOSThermalPressureNotificationName();

    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
        return kCPUthermalThermalPressureLevelError;
    }
    if (notify_get_state(token, &level) != NOTIFY_STATUS_OK) {
        notify_cancel(token);
        return kCPUthermalThermalPressureLevelError;
    }
    if (notify_cancel(token) != NOTIFY_STATUS_OK) {
        return kCPUthermalThermalPressureLevelError;
    }

    return CPUthermalPressureLevelFromRawOSThermalValue(level);
}

static inline int CPUthermalSetThermalPressureLevel(CPUthermalThermalPressureLevel pressure) {
    int token = 0;
    const char *name = CPUthermalOSThermalPressureNotificationName();

    if (pressure < kCPUthermalThermalPressureLevelNominal || pressure >= kCPUthermalThermalPressureLevelUnknown) {
        return 3;
    }
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
        return -1;
    }
    if (notify_set_state(token, CPUthermalRawOSThermalPressureLevel(pressure)) != NOTIFY_STATUS_OK) {
        notify_cancel(token);
        return 1;
    }
    notify_post(kCPUthermalThermalPressureNotifyBypassC);
    if (notify_post(name) != NOTIFY_STATUS_OK) {
        notify_cancel(token);
        return 2;
    }
    notify_cancel(token);
    return 0;
}

static inline BOOL CPUthermalGetSavedThermalPressureLevel(CPUthermalThermalPressureLevel *pressureOut) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    id value = prefs[S(kCPUthermalThermalPressureKeyC)];
    if ([value respondsToSelector:@selector(integerValue)]) {
        NSInteger pressure = [value integerValue];
        if (pressure >= kCPUthermalThermalPressureLevelNominal && pressure < kCPUthermalThermalPressureLevelUnknown) {
            if (pressureOut) {
                *pressureOut = (CPUthermalThermalPressureLevel)pressure;
            }
            return YES;
        }
    }

    return NO;
}

static inline BOOL CPUthermalSavedPowerModeIsFullPower(void) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    id mode = prefs[S("powerMode")];
    return ![mode isKindOfClass:[NSString class]] || ![(NSString *)mode isEqualToString:S("lowPower")];
}

static inline CPUthermalThermalPressureLevel CPUthermalSavedThermalPressureLevel(void) {
    CPUthermalThermalPressureLevel pressure = kCPUthermalThermalPressureLevelNominal;
    if (CPUthermalGetSavedThermalPressureLevel(&pressure)) {
        return pressure;
    }
    return kCPUthermalThermalPressureLevelNominal;
}

static inline int CPUthermalApplySavedThermalPressureLevel(void) {
    CPUthermalThermalPressureLevel pressure = kCPUthermalThermalPressureLevelNominal;
    if (!CPUthermalGetSavedThermalPressureLevel(&pressure)) {
        return CPUthermalSavedPowerModeIsFullPower() ? CPUthermalSetThermalPressureLevel(kCPUthermalThermalPressureLevelNominal) : 0;
    }
    return CPUthermalSetThermalPressureLevel(pressure);
}

static inline int CPUthermalApplyThermalPressureLevelViaTool(CPUthermalThermalPressureLevel pressure) {
    int directRet = CPUthermalSetThermalPressureLevel(pressure);
    if (directRet == 0) {
        return 0;
    }

    NSString *toolPath = CPUthermalToolPath();
    if (toolPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
        NSString *pressureArg = [NSString stringWithFormat:S("%ld"), (long)pressure];
        char *args[] = {
            (char *)"CPUthermalTool",
            (char *)"set-thermal-pressure",
            (char *)[pressureArg UTF8String],
            NULL
        };
        pid_t pid = 0;
        int status = 0;
        if (posix_spawn(&pid, [toolPath fileSystemRepresentation], NULL, NULL, args, NULL) == 0 && waitpid(pid, &status, 0) >= 0) {
            if (WIFEXITED(status)) {
                return WEXITSTATUS(status);
            }
            return status;
        }
    }
    return directRet;
}

static inline NSString *CPUthermalThermalNotificationTitle(CPUthermalThermalNotificationLevel level) {
    switch (level) {
        case kCPUthermalThermalNotificationLevelNormal:
            return S("正常");
        case kCPUthermalThermalNotificationLevel70PercentTorch:
            return S("手电筒 70%");
        case kCPUthermalThermalNotificationLevel70PercentBacklight:
            return S("背光 70%");
        case kCPUthermalThermalNotificationLevel50PercentTorch:
            return S("手电筒 50%");
        case kCPUthermalThermalNotificationLevel50PercentBacklight:
            return S("背光 50%");
        case kCPUthermalThermalNotificationLevelDisableTorch:
            return S("禁用手电筒");
        case kCPUthermalThermalNotificationLevel25PercentBacklight:
            return S("背光 25%");
        case kCPUthermalThermalNotificationLevelDisableMapsHalo:
            return S("禁用地图光晕");
        case kCPUthermalThermalNotificationLevelAppTerminate:
            return S("终止 App");
        case kCPUthermalThermalNotificationLevelDeviceRestart:
            return S("设备重启");
        case kCPUthermalThermalNotificationLevelThermalTableReady:
            return S("就绪");
        case kCPUthermalThermalNotificationLevelAny:
            return S("不可用");
        case kCPUthermalThermalNotificationLevelUnknown:
        default:
            return S("未知");
    }
}

static inline int CPUthermalCurrentThermalNotificationRawLevel(void) {
    if (&OSThermalNotificationCurrentLevel == NULL) {
        return INT_MIN;
    }
    return OSThermalNotificationCurrentLevel();
}

static inline CPUthermalThermalNotificationLevel CPUthermalCurrentThermalNotificationLevel(void) {
    const char *name = CPUthermalOSThermalNotificationName();
    if (!name || &OSThermalNotificationCurrentLevel == NULL) {
        return kCPUthermalThermalNotificationLevelAny;
    }

    int rawLevel = OSThermalNotificationCurrentLevel();
    if (rawLevel == 0) {
        return kCPUthermalThermalNotificationLevelNormal;
    }
    if (&_OSThermalNotificationLevelForBehavior != NULL) {
        for (int i = 0; i < kCPUthermalThermalNotificationLevelUnknown; i++) {
            if (_OSThermalNotificationLevelForBehavior(i) == rawLevel) {
                return (CPUthermalThermalNotificationLevel)i;
            }
        }
    }

    return kCPUthermalThermalNotificationLevelUnknown;
}

static inline NSString *CPUthermalThermalNotificationLabel(void) {
    CPUthermalThermalNotificationLevel level = CPUthermalCurrentThermalNotificationLevel();
    int rawLevel = CPUthermalCurrentThermalNotificationRawLevel();
    if (level == kCPUthermalThermalNotificationLevelAny || rawLevel == INT_MIN) {
        return CPUthermalThermalNotificationTitle(kCPUthermalThermalNotificationLevelAny);
    }
    return [NSString stringWithFormat:S("%@ (%d)"), CPUthermalThermalNotificationTitle(level), rawLevel];
}

static inline int CPUthermalSetThermalNotificationRawLevel(int level) {
    int token = 0;
    const char *name = CPUthermalOSThermalNotificationName();
    if (!name) {
        return -1;
    }
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
        return -1;
    }
    if (notify_set_state(token, level) != NOTIFY_STATUS_OK) {
        notify_cancel(token);
        return 1;
    }
    notify_post(kCPUthermalThermalNotificationNotifyBypassC);
    if (notify_post(name) != NOTIFY_STATUS_OK) {
        notify_cancel(token);
        return 2;
    }
    notify_cancel(token);
    return 0;
}

static inline int CPUthermalResetThermalNotificationViaTool(void) {
    int directRet = CPUthermalSetThermalNotificationRawLevel(0);
    if (directRet == 0) {
        return 0;
    }

    NSString *toolPath = CPUthermalToolPath();
    if (toolPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
        char *args[] = {
            (char *)"CPUthermalTool",
            (char *)"reset-thermal-notification",
            NULL
        };
        pid_t pid = 0;
        int status = 0;
        if (posix_spawn(&pid, [toolPath fileSystemRepresentation], NULL, NULL, args, NULL) == 0 && waitpid(pid, &status, 0) >= 0) {
            if (WIFEXITED(status)) {
                return WEXITSTATUS(status);
            }
            return status;
        }
    }
    return directRet;
}

// ============================================================================
// CPU频率锁定 — 手动选择芯片代际锁定频率
// ============================================================================
static const char *kCPUthermalDeviceLockKeyC = "deviceLock";

// 芯片代际 -> 最大频率(MHz) 映射
static inline NSInteger CPUthermalFrequencyForChipKey(NSString *chipKey) {
    if (!chipKey || chipKey.length == 0) return 0;
    // A11 (iPhone 8 / 8+ / X)
    if ([chipKey isEqualToString:S("A11")]) return 2390;
    // A12 (iPhone XS / XS Max / XR)
    if ([chipKey isEqualToString:S("A12")]) return 2490;
    // A13 (iPhone 11 / 11 Pro / Pro Max)
    if ([chipKey isEqualToString:S("A13")]) return 2660;
    // A14 (iPhone 12 mini / 12 / 12 Pro / Pro Max)
    if ([chipKey isEqualToString:S("A14")]) return 3100;
    // A15 (iPhone 13 / 14 / 14+)
    if ([chipKey isEqualToString:S("A15")]) return 3240;
    // A16 (iPhone 14 Pro / 15 / 15+)
    if ([chipKey isEqualToString:S("A16")]) return 3460;
    // A17 Pro (iPhone 15 Pro / Pro Max)
    if ([chipKey isEqualToString:S("A17Pro")]) return 3700;
    return 0;
}

// 芯片代际 -> 显示名称
static inline NSString *CPUthermalChipDisplayName(NSString *chipKey) {
    if (!chipKey || chipKey.length == 0) return S("无锁定");
    NSInteger freq = CPUthermalFrequencyForChipKey(chipKey);
    if (freq == 0) return S("无锁定");
    if ([chipKey isEqualToString:S("A11")])
        return [NSString stringWithFormat:S("A11 · %ld MHz (iPhone 8 ~ X)"), (long)freq];
    if ([chipKey isEqualToString:S("A12")])
        return [NSString stringWithFormat:S("A12 · %ld MHz (iPhone XS ~ XR)"), (long)freq];
    if ([chipKey isEqualToString:S("A13")])
        return [NSString stringWithFormat:S("A13 · %ld MHz (iPhone 11)"), (long)freq];
    if ([chipKey isEqualToString:S("A14")])
        return [NSString stringWithFormat:S("A14 · %ld MHz (iPhone 12)"), (long)freq];
    if ([chipKey isEqualToString:S("A15")])
        return [NSString stringWithFormat:S("A15 · %ld MHz (iPhone 13 / 14)"), (long)freq];
    if ([chipKey isEqualToString:S("A16")])
        return [NSString stringWithFormat:S("A16 · %ld MHz (iPhone 14 Pro / 15)"), (long)freq];
    if ([chipKey isEqualToString:S("A17Pro")])
        return [NSString stringWithFormat:S("A17 Pro · %ld MHz (iPhone 15 Pro)"), (long)freq];
    return S("无锁定");
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
