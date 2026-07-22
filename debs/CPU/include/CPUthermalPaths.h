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
static const char *kCPUthermalDefaultPowerModeC = "fullPower";
static const char *kCPUthermalLowPowerModeC = "lowPower";
static const char *kCPUthermalFullPowerModeC = "fullPower";
static const NSInteger kCPUthermalLowBatterySimulationSOCPct = 20;
static const NSInteger kCPUthermalDefaultMaxPCoreFrequencyMHz = 3240;

// 低功耗模式目标限制频率MHz（定义见 Tweak.x）
NSInteger lowPowerTargetValue(void);

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
