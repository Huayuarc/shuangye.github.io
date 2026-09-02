#ifndef APPLOWPOWER_PATHS_H
#define APPLOWPOWER_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>
#include <roothide.h>

#define S(str) [NSString stringWithUTF8String:(str)]

static const char *kALPPrefRootFSPathC = "/var/mobile/Library/Preferences/com.huayuarc.applowpower.plist";
static const char *kALPOldJBPrefRelativePathC = "Library/Preferences/com.huayuarc.applowpower.plist";
static const char *kALPSettingsChangedNotifC = "com.huayuarc.applowpower/settingsChanged";
static const char *kALPForegroundAppNotifC = "com.huayuarc.applowpower/foregroundApp";

static inline uint64_t ALPBundleIDHash(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return 0;
    const unsigned char *bytes = (const unsigned char *)[bundleID UTF8String];
    uint64_t hash = 1469598103934665603ULL;
    for (; bytes && *bytes; bytes++) { hash ^= *bytes; hash *= 1099511628211ULL; }
    return hash ?: 1;
}

static inline int ALPPostForegroundBundleID(NSString *bundleID) {
    int token = 0;
    if (notify_register_check(kALPForegroundAppNotifC, &token) != NOTIFY_STATUS_OK) return -1;
    int result = notify_set_state(token, ALPBundleIDHash(bundleID));
    if (result == NOTIFY_STATUS_OK) result = notify_post(kALPForegroundAppNotifC);
    notify_cancel(token);
    return result;
}

static inline BOOL ALPClearForegroundBundleIDIfCurrent(NSString *bundleID) {
    uint64_t ownHash = ALPBundleIDHash(bundleID);
    if (ownHash == 0) return NO;
    int token = 0;
    uint64_t currentHash = 0;
    if (notify_register_check(kALPForegroundAppNotifC, &token) != NOTIFY_STATUS_OK) return NO;
    int result = notify_get_state(token, &currentHash);
    if (result == NOTIFY_STATUS_OK && currentHash == ownHash) {
        result = notify_set_state(token, 0);
        if (result == NOTIFY_STATUS_OK) result = notify_post(kALPForegroundAppNotifC);
    }
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK && currentHash == ownHash;
}

static inline uint64_t ALPReadForegroundBundleHash(void) {
    int token = 0;
    uint64_t state = 0;
    if (notify_register_check(kALPForegroundAppNotifC, &token) != NOTIFY_STATUS_OK) return 0;
    int result = notify_get_state(token, &state);
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK ? state : 0;
}

static inline NSString *ALPStringFromCPath(const char *path) {
    return path ? [NSString stringWithUTF8String:path] : nil;
}

static inline NSString *ALPJBRootPathForRootFSPath(const char *path) {
    if (!path) return nil;
    const char *jbPath = jbroot(path);
    if (jbPath && strlen(jbPath) > 0) {
        NSString *converted = [NSString stringWithUTF8String:jbPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:converted]) return converted;
    }
    NSString *varJBPath = [S("/var/jb") stringByAppendingPathComponent:[NSString stringWithUTF8String:path]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:varJBPath]) return varJBPath;
    return [NSString stringWithUTF8String:path];
}

// RootHide 隐根 UUID 每次重越狱都会变化；动态挑选包含本插件 dylib 的当前根。
static inline NSString *ALPCurrentRootHideRoot(void) {
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
        if ([fileManager fileExistsAtPath:[root stringByAppendingPathComponent:S("Library/MobileSubstrate/DynamicLibraries/AppLowPower.dylib")]]) score += 1000;
        if ([fileManager fileExistsAtPath:[root stringByAppendingPathComponent:S("Library/MobileSubstrate")]]) score += 100;
        if ([fileManager fileExistsAtPath:[root stringByAppendingPathComponent:S("usr/lib")]]) score += 10;

        NSDictionary *attributes = [fileManager attributesOfItemAtPath:root error:nil];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!bestRoot || score > bestScore || (score == bestScore && [date compare:bestDate] == NSOrderedDescending)) {
            bestRoot = root; bestScore = score; bestDate = date;
        }
    }
    return bestRoot;
}

static inline NSString *ALPCurrentPrefPath(void) {
    NSString *rootHideRoot = ALPCurrentRootHideRoot();
    if (rootHideRoot.length > 0) {
        return [[rootHideRoot stringByAppendingPathComponent:S("var/mobile/Library/Preferences")]
            stringByAppendingPathComponent:S("com.huayuarc.applowpower.plist")];
    }
    const char *convertedPath = jbroot(kALPPrefRootFSPathC);
    if (convertedPath && strlen(convertedPath) > 0) {
        NSString *converted = [NSString stringWithUTF8String:convertedPath];
        if ([converted containsString:S("/Containers/Shared/AppGroup/.jbroot-")]) return converted;
    }
    return ALPJBRootPathForRootFSPath(kALPPrefRootFSPathC);
}

static inline NSString *ALPOldJBRootPrefPath(void) {
    NSString *resolved = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:S("/var/jb") error:nil];
    if (resolved.length > 0) return [resolved stringByAppendingPathComponent:S(kALPOldJBPrefRelativePathC)];
    return [S("/var/jb") stringByAppendingPathComponent:S(kALPOldJBPrefRelativePathC)];
}

static inline NSArray<NSString *> *ALPLegacyPrefPaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *appGroupRoot = S("/var/mobile/Containers/Shared/AppGroup");
    for (NSString *entry in [fileManager contentsOfDirectoryAtPath:appGroupRoot error:nil]) {
        if (![entry hasPrefix:S(".jbroot-")]) continue;
        NSString *candidate = [[[appGroupRoot stringByAppendingPathComponent:entry]
            stringByAppendingPathComponent:S("var/mobile/Library/Preferences")]
            stringByAppendingPathComponent:S("com.huayuarc.applowpower.plist")];
        if (![paths containsObject:candidate]) [paths addObject:candidate];
    }
    NSString *oldJBPath = ALPOldJBRootPrefPath();
    if (oldJBPath.length > 0 && ![paths containsObject:oldJBPath]) [paths addObject:oldJBPath];
    NSString *rootFSPath = ALPStringFromCPath(kALPPrefRootFSPathC);
    if (rootFSPath.length > 0 && ![paths containsObject:rootFSPath]) [paths addObject:rootFSPath];
    return paths;
}

static inline void ALPEnsurePrefDirectory(void) {
    NSString *directory = [ALPCurrentPrefPath() stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
}

static inline NSMutableDictionary *ALPReadMutablePrefs(void) {
    NSString *path = ALPCurrentPrefPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (prefs) {
        for (NSString *legacyPath in ALPLegacyPrefPaths())
            if (![legacyPath isEqualToString:path]) [fileManager removeItemAtPath:legacyPath error:nil];
        return prefs;
    }

    NSDictionary *newestLegacyPrefs = nil;
    NSDate *newestDate = nil;
    NSArray<NSString *> *legacyPaths = ALPLegacyPrefPaths();
    for (NSString *legacyPath in legacyPaths) {
        if ([legacyPath isEqualToString:path]) continue;
        NSDictionary *legacyPrefs = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
        if (!legacyPrefs) continue;
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:legacyPath error:nil];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!newestLegacyPrefs || [date compare:newestDate] == NSOrderedDescending) {
            newestLegacyPrefs = legacyPrefs; newestDate = date;
        }
    }
    if (newestLegacyPrefs) {
        prefs = [newestLegacyPrefs mutableCopy];
        ALPEnsurePrefDirectory();
        if ([prefs writeToFile:path atomically:YES])
            for (NSString *legacyPath in legacyPaths)
                if (![legacyPath isEqualToString:path]) [fileManager removeItemAtPath:legacyPath error:nil];
        return prefs;
    }
    return nil;
}

static inline NSDictionary *ALPReadPrefs(void) { return ALPReadMutablePrefs(); }

static inline BOOL ALPWritePrefs(NSDictionary *prefs) {
    if (!prefs) return NO;
    NSString *path = ALPCurrentPrefPath();
    ALPEnsurePrefDirectory();
    BOOL ok = [prefs writeToFile:path atomically:YES];
    if (ok) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSString *legacyPath in ALPLegacyPrefPaths())
            if (![legacyPath isEqualToString:path]) [fileManager removeItemAtPath:legacyPath error:nil];
    }
    return ok;
}

#endif
