#ifndef FACEDOWNLOCK_PATHS_H
#define FACEDOWNLOCK_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#include <roothide.h>

#define FDL_S(str) [NSString stringWithUTF8String:(str)]

static const char *kFDLPrefRootFSPathC = "/var/mobile/Library/Preferences/com.huayuarc.facedownlock.plist";
static const char *kFDLSettingsChangedNotifC = "com.huayuarc.facedownlock/settingsChanged";

static inline NSString *FDLCurrentRootHideRoot(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *appGroupRoot = FDL_S("/var/mobile/Containers/Shared/AppGroup");
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:appGroupRoot error:nil];
    NSString *bestRoot = nil;
    NSInteger bestScore = NSIntegerMin;
    NSDate *bestDate = nil;

    for (NSString *entry in entries) {
        if (![entry hasPrefix:FDL_S(".jbroot-")]) continue;
        NSString *root = [appGroupRoot stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) continue;
        NSInteger score = 0;
        if ([fileManager fileExistsAtPath:[root stringByAppendingPathComponent:FDL_S("Library/MobileSubstrate/DynamicLibraries/FaceDownLock.dylib")]]) score += 1000;
        if ([fileManager fileExistsAtPath:[root stringByAppendingPathComponent:FDL_S("Library/MobileSubstrate")]]) score += 100;
        if ([fileManager fileExistsAtPath:[root stringByAppendingPathComponent:FDL_S("usr/lib")]]) score += 10;
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:root error:nil];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!bestRoot || score > bestScore || (score == bestScore && [date compare:bestDate] == NSOrderedDescending)) {
            bestRoot = root; bestScore = score; bestDate = date;
        }
    }
    return bestRoot;
}

static inline NSString *FDLCurrentPrefPath(void) {
    NSString *root = FDLCurrentRootHideRoot();
    if (root.length > 0)
        return [[root stringByAppendingPathComponent:FDL_S("var/mobile/Library/Preferences")]
            stringByAppendingPathComponent:FDL_S("com.huayuarc.facedownlock.plist")];

    const char *converted = jbroot(kFDLPrefRootFSPathC);
    if (converted && strlen(converted) > 0) {
        NSString *path = FDL_S(converted);
        if ([path containsString:FDL_S("/Containers/Shared/AppGroup/.jbroot-")]) return path;
        if ([[NSFileManager defaultManager] fileExistsAtPath:[path stringByDeletingLastPathComponent]]) return path;
    }
    return FDL_S(kFDLPrefRootFSPathC);
}

static inline NSMutableDictionary *FDLReadMutablePrefs(void) {
    NSString *path = FDLCurrentPrefPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (prefs) return prefs;

    // 从原 CPUthermal 配置迁移一次，仅复制朝下锁屏开关，不触碰其他插件设置。
    NSArray *legacyPaths = @[
        FDL_S("/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist"),
        FDL_S("/var/jb/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist")
    ];
    for (NSString *legacy in legacyPaths) {
        NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:legacy];
        id value = old[FDL_S("lockWhenFaceDown")];
        if (!value) continue;
        prefs = [@{FDL_S("enabled"): @([value boolValue])} mutableCopy];
        NSString *directory = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        [prefs writeToFile:path atomically:YES];
        return prefs;
    }
    return nil;
}

static inline NSDictionary *FDLReadPrefs(void) { return FDLReadMutablePrefs(); }

static inline BOOL FDLWritePrefs(NSDictionary *prefs) {
    if (!prefs) return NO;
    NSString *path = FDLCurrentPrefPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [prefs writeToFile:path atomically:YES];
}

#endif
