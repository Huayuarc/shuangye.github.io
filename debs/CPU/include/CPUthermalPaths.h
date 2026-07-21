#ifndef CPUTHERMAL_PATHS_H
#define CPUTHERMAL_PATHS_H

#import <Foundation/Foundation.h>
#include <roothide.h>
#include <dispatch/dispatch.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict attr, uid_t persona_id, uint32_t flags);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict attr, uid_t uid);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict attr, uid_t gid);

#define S(str) [NSString stringWithUTF8String:(str)]

static const char *kCPUthermalPrefRootFSPathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kCPUthermalOldJBPrefRelativePathC = "Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kCPUthermalSettingsChangedNotifC = "com.huayuarc.CPUthermal/settingsChanged";
static const char *kCPUthermalPowerModeChangedNotifC = "com.huayuarc.CPUthermal/powerModeChanged";
static const char *kCPUthermalDisableHotInPocketKeyC = "disableHotInPocket";
static const char *kCPUthermalLockSunlightExposureKeyC = "lockSunlightExposure";
static const char *kCPUthermalLowPowerModeC = "lowPower";
static const char *kCPUthermalFullPowerModeC = "fullPower";
static const char *kCPUthermalDefaultPowerModeC = "fullPower";
static const NSInteger kCPUthermalDefaultLowPowerFrequencyMHz = 2016;
static const NSInteger kCPUthermalDefaultMaxPCoreFrequencyMHz = 3240;

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
    if ([hardware isEqualToString:S("iPhone10,1")] ||
        [hardware isEqualToString:S("iPhone10,2")] ||
        [hardware isEqualToString:S("iPhone10,3")] ||
        [hardware isEqualToString:S("iPhone10,4")] ||
        [hardware isEqualToString:S("iPhone10,5")] ||
        [hardware isEqualToString:S("iPhone10,6")]) {
        return 2390;
    }
    if ([hardware isEqualToString:S("iPhone11,2")] ||
        [hardware isEqualToString:S("iPhone11,4")] ||
        [hardware isEqualToString:S("iPhone11,6")] ||
        [hardware isEqualToString:S("iPhone11,8")]) {
        return 2490;
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
    if ([chipKey isEqualToString:S("A13")]) return 2650;
    // A14 (iPhone 12 mini / 12 / 12 Pro / Pro Max)
    if ([chipKey isEqualToString:S("A14")]) return 3090;
    // A15 (iPhone 13 / 14 / 14+)
    if ([chipKey isEqualToString:S("A15")]) return 3230;
    // A16 (iPhone 14 Pro / 15 / 15+)
    if ([chipKey isEqualToString:S("A16")]) return 3460;
    // A17 Pro (iPhone 15 Pro / Pro Max)
    if ([chipKey isEqualToString:S("A17Pro")]) return 3780;
    return 0;
}

// 芯片代际 -> 显示名称
static inline NSString *CPUthermalChipDisplayName(NSString *chipKey) {
    if (!chipKey || chipKey.length == 0) return S("无锁定（自动）");
    NSInteger freq = CPUthermalFrequencyForChipKey(chipKey);
    if (freq == 0) return S("无锁定（自动）");
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
    return S("无锁定（自动）");
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

static inline void CPUthermalSpawnRootDetached(NSString *path, char *const args[]) {
    if (path.length == 0) {
        return;
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, 1);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    pid_t pid = 0;
    if (posix_spawn(&pid, [path fileSystemRepresentation], NULL, &attr, args, NULL) == 0) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            waitpid(pid, NULL, 0);
        });
    }
    posix_spawnattr_destroy(&attr);
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
        CPUthermalSpawnRootDetached(toolPath, args);
        return;
    }

    NSString *killallPath = CPUthermalKillallPath();
    if (killallPath.length > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
