#ifndef CPUTHERMAL_PATHS_H
#define CPUTHERMAL_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>
#include <string.h>
#include <roothide.h>

#define S(str) [NSString stringWithUTF8String:(str)]

static const char *kCPUthermalSettingsChangedNotifC = "com.huayuarc.cputhermal/settingsChanged";
static const char *kCPUthermalForegroundAppNotifC = "com.huayuarc.cputhermal/foregroundApp";
static const char *kCPUthermalPrefPathC = "/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist";

static inline uint64_t CPUthermalBundleIDHash(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) return 0;
    const unsigned char *bytes = (const unsigned char *)bundleID.UTF8String;
    uint64_t hash = 1469598103934665603ULL;
    for (; bytes && *bytes; bytes++) { hash ^= *bytes; hash *= 1099511628211ULL; }
    return hash ?: 1;
}

static inline int CPUthermalPostForegroundBundleID(NSString *bundleID) {
    int token = 0;
    if (notify_register_check(kCPUthermalForegroundAppNotifC, &token) != NOTIFY_STATUS_OK) return -1;
    int result = notify_set_state(token, CPUthermalBundleIDHash(bundleID));
    if (result == NOTIFY_STATUS_OK) result = notify_post(kCPUthermalForegroundAppNotifC);
    notify_cancel(token);
    return result;
}

static inline BOOL CPUthermalClearForegroundBundleIDIfCurrent(NSString *bundleID) {
    uint64_t ownHash = CPUthermalBundleIDHash(bundleID), current = 0;
    int token = 0;
    if (!ownHash || notify_register_check(kCPUthermalForegroundAppNotifC, &token) != NOTIFY_STATUS_OK) return NO;
    int result = notify_get_state(token, &current);
    if (result == NOTIFY_STATUS_OK && current == ownHash) {
        result = notify_set_state(token, 0);
        if (result == NOTIFY_STATUS_OK) result = notify_post(kCPUthermalForegroundAppNotifC);
    }
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK && current == ownHash;
}

static inline uint64_t CPUthermalReadForegroundBundleHash(void) {
    int token = 0; uint64_t state = 0;
    if (notify_register_check(kCPUthermalForegroundAppNotifC, &token) != NOTIFY_STATUS_OK) return 0;
    int result = notify_get_state(token, &state);
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK ? state : 0;
}

static inline NSString *CPUthermalCurrentRootHideRoot(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = S("/var/mobile/Containers/Shared/AppGroup");
    NSString *best = nil; NSInteger bestScore = NSIntegerMin; NSDate *bestDate = nil;
    for (NSString *entry in [fm contentsOfDirectoryAtPath:base error:nil] ?: @[]) {
        if (![entry hasPrefix:S(".jbroot-")]) continue;
        NSString *root = [base stringByAppendingPathComponent:entry]; BOOL directory = NO;
        if (![fm fileExistsAtPath:root isDirectory:&directory] || !directory) continue;
        NSInteger score = 0;
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:S("Library/MobileSubstrate/DynamicLibraries/CPUthermal.dylib")]]) score += 1000;
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:S("Library/MobileSubstrate")]]) score += 100;
        NSDate *date = [fm attributesOfItemAtPath:root error:nil][NSFileModificationDate] ?: NSDate.distantPast;
        if (!best || score > bestScore || (score == bestScore && [date compare:bestDate] == NSOrderedDescending)) {
            best = root; bestScore = score; bestDate = date;
        }
    }
    return best;
}

static inline NSString *CPUthermalCurrentPrefPath(void) {
    NSString *root = CPUthermalCurrentRootHideRoot();
    if (root.length) return [root stringByAppendingPathComponent:S("var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist")];
    const char *converted = jbroot(kCPUthermalPrefPathC);
    if (converted && strlen(converted)) return S(converted);
    return S(kCPUthermalPrefPathC);
}

static inline NSArray<NSString *> *CPUthermalLegacyPrefPaths(void) {
    NSMutableArray *paths = [NSMutableArray arrayWithObject:S(kCPUthermalPrefPathC)];
    NSString *base = S("/var/mobile/Containers/Shared/AppGroup");
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:nil] ?: @[])
        if ([entry hasPrefix:S(".jbroot-")]) [paths addObject:[[base stringByAppendingPathComponent:entry] stringByAppendingPathComponent:S("var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist")]];
    return paths;
}

static inline NSMutableDictionary *CPUthermalReadMutablePrefs(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *current = CPUthermalCurrentPrefPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:current];
    if (prefs) return prefs;
    NSDictionary *newest = nil; NSDate *newestDate = nil;
    for (NSString *path in CPUthermalLegacyPrefPaths()) {
        if ([path isEqualToString:current]) continue;
        NSDictionary *candidate = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!candidate) continue;
        NSDate *date = [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate] ?: NSDate.distantPast;
        if (!newest || [date compare:newestDate] == NSOrderedDescending) { newest = candidate; newestDate = date; }
    }
    if (!newest) return nil;
    prefs = [newest mutableCopy];
    [fm createDirectoryAtPath:current.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [prefs writeToFile:current atomically:YES];
    return prefs;
}

static inline NSDictionary *CPUthermalReadPrefs(void) { return CPUthermalReadMutablePrefs(); }

static inline BOOL CPUthermalWritePrefs(NSDictionary *prefs) {
    if (!prefs) return NO;
    NSString *path = CPUthermalCurrentPrefPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL ok = [prefs writeToFile:path atomically:YES];
    if (ok) for (NSString *legacy in CPUthermalLegacyPrefPaths()) if (![legacy isEqualToString:path]) [NSFileManager.defaultManager removeItemAtPath:legacy error:nil];
    return ok;
}

#endif
