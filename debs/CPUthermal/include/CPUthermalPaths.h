#ifndef CPUTHERMAL_PATHS_H
#define CPUTHERMAL_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>
#include <roothide.h>

#define S(str) [NSString stringWithUTF8String:(str)]

static const char *kCPUthermalPrefRootFSPathC = "/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist";
static const char *kCPUthermalOldJBPrefRelativePathC = "Library/Preferences/com.huayuarc.cputhermal.plist";
static const char *kCPUthermalSettingsChangedNotifC = "com.huayuarc.cputhermal/settingsChanged";
static const char *kCPUthermalPowerModeChangedNotifC = "com.huayuarc.cputhermal/powerModeChanged";
static const char *kCPUthermalMaximumCapacityNotifC = "com.huayuarc.cputhermal/maximumCapacityState";
static const char *kCPUthermalRefreshRateNotifC = "com.huayuarc.cputhermal/refreshRateState";
static const char *kCPUthermalLowPowerModeC = "lowPower";
static const char *kCPUthermalFullPowerModeC = "fullPower";
static const uint64_t kCPUthermalPowerModeStateFull = 0;
static const uint64_t kCPUthermalPowerModeStateLow = 1;

// Darwin notify state 直接携带模式，避免 thermalmonitord 因偏好路径/缓存读到旧值。
static inline int CPUthermalPostPowerMode(NSString *mode) {
    int token = 0;
    if (notify_register_check(kCPUthermalPowerModeChangedNotifC, &token) != NOTIFY_STATUS_OK) return -1;
    uint64_t state = [mode isEqualToString:S(kCPUthermalLowPowerModeC)]
        ? kCPUthermalPowerModeStateLow : kCPUthermalPowerModeStateFull;
    int result = notify_set_state(token, state);
    if (result == NOTIFY_STATUS_OK) result = notify_post(kCPUthermalPowerModeChangedNotifC);
    notify_cancel(token);
    return result;
}

static inline BOOL CPUthermalReadPostedPowerMode(BOOL *lowPower) {
    int token = 0;
    uint64_t state = UINT64_MAX;
    if (notify_register_check(kCPUthermalPowerModeChangedNotifC, &token) != NOTIFY_STATUS_OK) return NO;
    int result = notify_get_state(token, &state);
    notify_cancel(token);
    if (result != NOTIFY_STATUS_OK || state > kCPUthermalPowerModeStateLow) return NO;
    if (lowPower) *lowPower = (state == kCPUthermalPowerModeStateLow);
    return YES;
}

static inline void CPUthermalPostRefreshRateState(BOOL force120, BOOL globalInjection, BOOL enhanced) {
    int token=0;if(notify_register_check(kCPUthermalRefreshRateNotifC,&token)!=NOTIFY_STATUS_OK)return;
    uint64_t state=(force120?1ULL:0ULL)|(globalInjection?2ULL:0ULL)|(enhanced?4ULL:0ULL);
    notify_set_state(token,state);notify_post(kCPUthermalRefreshRateNotifC);notify_cancel(token);
}
static inline BOOL CPUthermalReadRefreshRateState(BOOL *force120, BOOL *globalInjection, BOOL *enhanced) {
    int token=0;uint64_t state=0;if(notify_register_check(kCPUthermalRefreshRateNotifC,&token)!=NOTIFY_STATUS_OK)return NO;
    int result=notify_get_state(token,&state);notify_cancel(token);if(result!=NOTIFY_STATUS_OK)return NO;
    if(force120)*force120=(state&1ULL)!=0;if(globalInjection)*globalInjection=(state&2ULL)!=0;if(enhanced)*enhanced=(state&4ULL)!=0;return YES;
}

static inline NSDictionary *CPUthermalReadPrefs(void);

static inline uint64_t CPUthermalRefreshBundleHash(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return 0;
    const unsigned char *bytes=(const unsigned char *)bundleID.UTF8String; uint64_t hash=1469598103934665603ULL;
    for(;bytes&&*bytes;bytes++){hash^=*bytes;hash*=1099511628211ULL;} return hash?:1;
}
static inline NSString *CPUthermalRefreshExclusionNotification(NSString *bundleID) {
    return [S("com.huayuarc.cputhermal/refreshExclude/") stringByAppendingFormat:S("%016llx"),(unsigned long long)CPUthermalRefreshBundleHash(bundleID)];
}
static inline void CPUthermalPostRefreshExclusion(NSString *bundleID, BOOL excluded) {
    NSString *name=CPUthermalRefreshExclusionNotification(bundleID); if(!name.length)return; int token=0;
    if(notify_register_check(name.UTF8String,&token)!=NOTIFY_STATUS_OK)return;notify_set_state(token,excluded?1:0);notify_post(name.UTF8String);notify_cancel(token);
}
static inline BOOL CPUthermalRefreshAppExcluded(NSString *bundleID) {
    if(!bundleID.length)return NO; NSString *name=CPUthermalRefreshExclusionNotification(bundleID);int token=0;uint64_t state=0;
    if(notify_register_check(name.UTF8String,&token)==NOTIFY_STATUS_OK){int result=notify_get_state(token,&state);notify_cancel(token);if(result==NOTIFY_STATUS_OK&&state==1)return YES;}
    NSDictionary *prefs=CPUthermalReadPrefs();NSArray *excluded=[prefs[S("refreshRateExcludedApps")] isKindOfClass:[NSArray class]]?prefs[S("refreshRateExcludedApps")]:nil;
    return [excluded containsObject:bundleID];
}

static inline void CPUthermalPostMaximumCapacityState(BOOL enabled) {
    int token = 0;
    if (notify_register_check(kCPUthermalMaximumCapacityNotifC, &token) != NOTIFY_STATUS_OK) return;
    notify_set_state(token, enabled ? 1 : 0);
    notify_post(kCPUthermalMaximumCapacityNotifC);
    notify_cancel(token);
}

static inline BOOL CPUthermalMaximumCapacityState(void) {
    int token = 0;
    uint64_t state = 0;
    if (notify_register_check(kCPUthermalMaximumCapacityNotifC, &token) != NOTIFY_STATUS_OK) return NO;
    int result = notify_get_state(token, &state);
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK && state == 1;
}

static inline NSString *CPUthermalStringFromCPath(const char *path) {
    return path ? [NSString stringWithUTF8String:path] : nil;
}

static inline NSString *CPUthermalJBRootPathForRootFSPath(const char *path) {
    if (!path) return nil;

    // 优先尝试通过 jbroot 转换路径
    const char *jbPath = jbroot(path);
    if (jbPath && strlen(jbPath) > 0) {
        NSString *converted = [NSString stringWithUTF8String:jbPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:converted]) {
            return converted;
        }
    }

    // 兜底 1: 检查 /var/jb 相对路径
    NSString *varJBPath = [S("/var/jb") stringByAppendingPathComponent:[NSString stringWithUTF8String:path]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:varJBPath]) {
        return varJBPath;
    }

    // 兜底 2: 返回原始路径
    return [NSString stringWithUTF8String:path];
}

static inline NSString *CPUthermalCurrentRootHideRoot(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *appGroupRoot = S("/var/mobile/Containers/Shared/AppGroup");
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:appGroupRoot error:nil];
    NSString *bestRoot = nil;
    NSInteger bestScore = NSIntegerMin;
    NSDate *bestDate = nil;

    for (NSString *entry in entries) {
        if (![entry hasPrefix:S(".jbroot-")]) continue;
        NSString *root = [appGroupRoot stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) continue;

        NSInteger score = 0;
        NSString *tweakPath = [root stringByAppendingPathComponent:S("Library/MobileSubstrate/DynamicLibraries/CPUthermal.dylib")];
        NSString *substratePath = [root stringByAppendingPathComponent:S("Library/MobileSubstrate")];
        NSString *usrLibPath = [root stringByAppendingPathComponent:S("usr/lib")];
        if ([fileManager fileExistsAtPath:tweakPath]) score += 1000;
        if ([fileManager fileExistsAtPath:substratePath]) score += 100;
        if ([fileManager fileExistsAtPath:usrLibPath]) score += 10;

        NSDictionary *attributes = [fileManager attributesOfItemAtPath:root error:nil];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!bestRoot || score > bestScore || (score == bestScore && [date compare:bestDate] == NSOrderedDescending)) {
            bestRoot = root;
            bestScore = score;
            bestDate = date;
        }
    }
    return bestRoot;
}

static inline NSString *CPUthermalCurrentPrefPath(void) {
    // 先动态定位当前 .jbroot-UUID，避免部分 RootHide 进程中的 jbroot(/var/mobile/...)
    // 仍返回真实 var 路径。UUID 每次重越狱变化也能自动重新发现。
    NSString *rootHideRoot = CPUthermalCurrentRootHideRoot();
    if (rootHideRoot.length > 0) {
        return [[rootHideRoot stringByAppendingPathComponent:S("var/mobile/Library/Preferences")]
            stringByAppendingPathComponent:S("com.huayuarc.cputhermal.plist")];
    }

    const char *convertedPath = jbroot(kCPUthermalPrefRootFSPathC);
    if (convertedPath && strlen(convertedPath) > 0) {
        NSString *converted = [NSString stringWithUTF8String:convertedPath];
        if ([converted containsString:S("/Containers/Shared/AppGroup/.jbroot-")]) return converted;
    }
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
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // RootHide 重新生成环境后 UUID 会变化；扫描全部旧 .jbroot-* 偏好副本并迁移。
    NSString *appGroupRoot = S("/var/mobile/Containers/Shared/AppGroup");
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:appGroupRoot error:nil];
    for (NSString *entry in entries) {
        if (![entry hasPrefix:S(".jbroot-")]) continue;
        NSString *candidate = [[[appGroupRoot stringByAppendingPathComponent:entry]
            stringByAppendingPathComponent:S("var/mobile/Library/Preferences")]
            stringByAppendingPathComponent:S("com.huayuarc.cputhermal.plist")];
        if (![paths containsObject:candidate]) [paths addObject:candidate];
    }

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
    if (!rootFSPath) return nil;
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
    return nil;
}

static inline NSString *CPUthermalLaunchctlPath(void) {
    return CPUthermalExistingExecutablePath("/usr/bin/launchctl", @[
        S("/var/jb/usr/bin/launchctl"),
        S("/var/jb/bin/launchctl"),
        S("/usr/bin/launchctl"),
        S("/bin/launchctl")
    ]);
}

static inline NSString *CPUthermalToolPath(void) {
    return CPUthermalExistingExecutablePath("/usr/local/bin/CPUthermalTool", @[
        S("/var/jb/usr/local/bin/CPUthermalTool"),
        S("/usr/local/bin/CPUthermalTool")
    ]);
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
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (prefs) {
        // 当前隐根配置有效时，清掉真实 var 和旧 UUID 副本，避免被 var 清理继续识别。
        for (NSString *legacyPath in CPUthermalLegacyPrefPaths()) {
            if (![legacyPath isEqualToString:path]) {
                [fileManager removeItemAtPath:legacyPath error:nil];
            }
        }
        return prefs;
    }


    NSString *newestLegacyPath = nil;
    NSDictionary *newestLegacyPrefs = nil;
    NSDate *newestDate = nil;
    NSArray<NSString *> *legacyPaths = CPUthermalLegacyPrefPaths();
    for (NSString *legacyPath in legacyPaths) {
        if ([legacyPath isEqualToString:path]) continue;
        NSDictionary *legacyPrefs = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
        if (!legacyPrefs) continue;
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:legacyPath error:nil];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!newestLegacyPrefs || [date compare:newestDate] == NSOrderedDescending) {
            newestLegacyPath = legacyPath;
            newestLegacyPrefs = legacyPrefs;
            newestDate = date;
        }
    }

    if (newestLegacyPrefs) {
        prefs = [newestLegacyPrefs mutableCopy];
        CPUthermalEnsurePrefDirectory();
        if ([prefs writeToFile:path atomically:YES]) {
            for (NSString *legacyPath in legacyPaths) {
                if (![legacyPath isEqualToString:path]) {
                    [fileManager removeItemAtPath:legacyPath error:nil];
                }
            }
        }
        (void)newestLegacyPath;
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
