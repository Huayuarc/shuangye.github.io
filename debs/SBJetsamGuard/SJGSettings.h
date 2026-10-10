#ifndef SJG_SETTINGS_H
#define SJG_SETTINGS_H
#include "SJGPaths.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <stdlib.h>
#include <sys/file.h>
#include <unistd.h>

static inline NSString *SJGStringPath(const char *path) {
    return path ? [NSString stringWithUTF8String:path] : nil;
}
static inline NSString *SJGPreferencesPath(void) {
    char path[PATH_MAX];
    return SJGCopyPreferencesPath(path, sizeof(path)) ? SJGStringPath(path) : nil;
}
static inline NSString *SJGStatusPath(void) {
    char path[PATH_MAX];
    return SJGCopyStatusPath(path, sizeof(path)) ? SJGStringPath(path) : nil;
}
static inline BOOL SJGFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.huayuarc.sbjetsamguard"
                                          code:1 userInfo:@{NSLocalizedDescriptionKey:message ?: @"操作失败"}];
    return NO;
}
static inline NSDictionary *SJGDefaultSettings(void) {
    return @{@"enabled":@YES, @"limitPreset":@"adaptive", @"cleanAppCaches":@NO,
             @"experimentalSysctls":@NO, @"threadTune":@NO, @"vnodeTune":@NO,
             @"sysprocsIdleTune":@NO, @"appsIdleTune":@NO,
             @"pressureDelayTune":@NO, @"vmWorkTune":@NO};
}
static inline id SJGValidatedValue(NSString *key, id value) {
    id fallback = SJGDefaultSettings()[key];
    if ([key isEqualToString:@"limitPreset"]) {
        NSString *preset = [value isKindOfClass:[NSString class]] ? value :
                          ([value isKindOfClass:[NSNumber class]] ? [value stringValue] : nil);
        return [@[@"adaptive", @"1024", @"1536", @"2048"] containsObject:preset ?: @""] ? preset : nil;
    }
    if (fallback) return [value isKindOfClass:[NSNumber class]] ? @([value boolValue]) : nil;
    return value;
}
static inline NSDictionary *SJGNormalizeSettings(NSDictionary *raw) {
    NSMutableDictionary *result = [SJGDefaultSettings() mutableCopy];
    if ([raw isKindOfClass:[NSDictionary class]]) {
        [result addEntriesFromDictionary:raw];
        for (NSString *key in SJGDefaultSettings())
            result[key] = SJGValidatedValue(key, raw[key]) ?: SJGDefaultSettings()[key];
    }
    return result;
}
static inline NSDictionary *SJGReadPlist(NSString *path) {
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    id plist = data ? [NSPropertyListSerialization propertyListWithData:data
                       options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
}

/* Both root helper and mobile Settings must be able to replace the same file. */
static inline BOOL SJGEnsureDirectory(NSString *path, NSError **error) {
    if (!path.length) return SJGFail(error, @"共享偏好路径不可用");
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if ([fm fileExistsAtPath:dir isDirectory:&isDirectory]) {
        if (!isDirectory) return SJGFail(error, @"偏好目录被非目录文件占用");
        /* Only this shared Preferences directory, never its ancestors or other files. */
        if (geteuid() == 0 &&
            ![fm setAttributes:@{NSFilePosixPermissions:@0755, NSFileOwnerAccountID:@501,
                                 NSFileGroupOwnerAccountID:@501} ofItemAtPath:dir error:error]) return NO;
        return YES;
    }
    NSMutableDictionary *attributes = [@{NSFilePosixPermissions:@0755} mutableCopy];
    if (geteuid() == 0) {
        attributes[NSFileOwnerAccountID] = @501;
        attributes[NSFileGroupOwnerAccountID] = @501;
    }
    return [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                         attributes:attributes error:error];
}

/* Advisory lock serializes read/migrate/modify/rename across helper + Prefs. */
static inline int SJGLockSettings(NSString *path, NSError **error) {
    if (!SJGEnsureDirectory(path, error)) return -1;
    NSString *lockPath = [path stringByAppendingString:@".lock"];
    int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0644);
    if (fd < 0) { SJGFail(error, @"无法打开共享偏好锁（请检查目录权限）"); return -1; }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1) {
        close(fd); SJGFail(error, @"共享偏好锁不是独立普通文件"); return -1;
    }
    if (geteuid() == 0 && (fchown(fd, 501, 501) || fchmod(fd, 0644))) {
        close(fd); SJGFail(error, @"无法设置共享偏好锁权限"); return -1;
    }
    int rc;
    do { rc = flock(fd, LOCK_EX); } while (rc < 0 && errno == EINTR);
    if (rc < 0) { close(fd); SJGFail(error, @"无法锁定共享偏好"); return -1; }
    return fd;
}
static inline void SJGUnlockSettings(int fd) {
    if (fd >= 0) { flock(fd, LOCK_UN); close(fd); }
}

/* Same-directory mkstemp + rename: never truncate a live plist. */
static inline BOOL SJGAtomicWritePlist(NSDictionary *plist, NSString *path, NSError **error) {
    if (![plist isKindOfClass:[NSDictionary class]] || !SJGEnsureDirectory(path, error))
        return SJGFail(error, @"偏好必须是有效字典且目标目录可写");
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                     format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    NSString *templatePath = [path stringByAppendingString:@".tmp.XXXXXX"];
    char *temp = strdup(templatePath.fileSystemRepresentation);
    if (!temp) return SJGFail(error, @"无法分配原子写入路径");
    int fd = mkstemp(temp);
    BOOL ok = fd >= 0;
    if (ok && geteuid() == 0) ok = fchown(fd, 501, 501) == 0;
    if (ok) ok = fchmod(fd, 0644) == 0;
    const unsigned char *bytes = data.bytes;
    size_t remaining = data.length;
    while (ok && remaining) {
        ssize_t n = write(fd, bytes, remaining);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = NO; break; }
        bytes += n; remaining -= (size_t)n;
    }
    if (ok) ok = fsync(fd) == 0;
    if (fd >= 0 && close(fd)) ok = NO;
    if (ok) ok = rename(temp, path.fileSystemRepresentation) == 0;
    if (!ok) unlink(temp);
    free(temp);
    if (!ok) return SJGFail(error, @"原子写入失败（请检查权限和剩余存储）");
    return YES;
}

static inline void SJGCollectPreferenceRoot(const char *root, void *context) {
    NSMutableOrderedSet *paths = (__bridge NSMutableOrderedSet *)context;
    NSString *base = SJGStringPath(root);
    [paths addObject:[base stringByAppendingFormat:@"%s/%s", SJG_PREFS_SUFFIX, SJG_PREFS_FILENAME]];
    [paths addObject:[base stringByAppendingFormat:@"/.jbroot%s/%s", SJG_PREFS_SUFFIX, SJG_PREFS_FILENAME]];
}
static inline NSArray *SJGLegacyPreferencePaths(NSString *destination) {
    NSMutableOrderedSet *paths = [NSMutableOrderedSet orderedSet];
    if (destination) [paths addObject:destination]; /* ties favor active path */
    SJGVisitRootHideRoots(SJGCollectPreferenceRoot, (__bridge void *)paths);
    [paths addObject:[NSString stringWithFormat:@"%s%s/%s", SJG_ROOTLESS_ROOT,
                      SJG_PREFS_SUFFIX, SJG_PREFS_FILENAME]];
    [paths addObject:[NSString stringWithFormat:@"%s/%s", SJG_REAL_PREFS_ROOT,
                      SJG_PREFS_FILENAME]];
    return paths.array;
}

/* Caller holds destination lock. Only valid dictionary plists participate. */
static inline NSDictionary *SJGMigrateSettingsLocked(NSString *destination, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = SJGLegacyPreferencePaths(destination);
    NSDictionary *best = nil;
    NSDate *bestDate = nil;
    NSString *bestPath = nil;
    for (NSString *path in paths) {
        NSDictionary *candidate = SJGReadPlist(path);
        if (!candidate) continue;
        NSDate *modified = [fm attributesOfItemAtPath:path error:NULL][NSFileModificationDate];
        if (!modified) continue;
        if (!best || [modified compare:bestDate] == NSOrderedDescending) {
            best = candidate; bestDate = modified; bestPath = path;
        }
    }
    if (!best) return @{};
    if (![bestPath isEqualToString:destination]) {
        if (!SJGAtomicWritePlist(best, destination, error)) return best;
        if (![SJGReadPlist(destination) isEqualToDictionary:best]) {
            SJGFail(error, @"迁移后读回校验失败，旧副本已保留"); return best;
        }
        /* Keep original mtime so first launch does not fabricate a newer setting. */
        [fm setAttributes:@{NSFileModificationDate:bestDate} ofItemAtPath:destination error:NULL];
    }
    /* Never erase unrelated/newer/corrupt data. Remove only verified old dictionaries. */
    for (NSString *path in paths) {
        if ([path isEqualToString:destination]) continue;
        if ([[path stringByResolvingSymlinksInPath] isEqualToString:
              [destination stringByResolvingSymlinksInPath]]) continue;
        NSDate *modified = [fm attributesOfItemAtPath:path error:NULL][NSFileModificationDate];
        if (modified && [modified compare:bestDate] != NSOrderedDescending && SJGReadPlist(path))
            [fm removeItemAtPath:path error:NULL];
    }
    return best;
}

static inline NSDictionary *SJGReadSettingsWithError(NSError **error) {
    if (error) *error = nil;
    NSString *path = SJGPreferencesPath();
    int lock = SJGLockSettings(path, error);
    if (lock < 0) return SJGNormalizeSettings(SJGReadPlist(path));
    NSDictionary *raw = SJGMigrateSettingsLocked(path, error);
    SJGUnlockSettings(lock);
    return SJGNormalizeSettings(raw);
}

/* nil removes a key; next read uses its documented default. Unknown keys preserved. */
static inline BOOL SJGWriteSetting(NSString *key, id value, NSError **error) {
    if (error) *error = nil;
    if (![key isKindOfClass:[NSString class]] || !key.length)
        return SJGFail(error, @"偏好键不可为空");
    id validated = value ? SJGValidatedValue(key, value) : nil;
    if (value && !validated) return SJGFail(error, @"无效的偏好值");
    NSString *path = SJGPreferencesPath();
    int lock = SJGLockSettings(path, error);
    if (lock < 0) return NO;
    NSError *migrationError = nil;
    NSMutableDictionary *raw = [SJGMigrateSettingsLocked(path, &migrationError) mutableCopy];
    BOOL ok = migrationError == nil;
    if (ok) {
        if (validated) raw[key] = validated; else [raw removeObjectForKey:key];
        ok = SJGAtomicWritePlist(raw, path, error);
    } else if (error) *error = migrationError;
    SJGUnlockSettings(lock);
    if (ok) notify_post(SJG_SETTINGS_CHANGED);
    return ok;
}

/* Fixed public API. WriteSettings merges keys, preserving unrelated preferences. */
static inline NSDictionary *SJGReadSettings(void) { return SJGReadSettingsWithError(NULL); }
static inline BOOL SJGWriteSettings(NSDictionary *settings) {
    if (![settings isKindOfClass:[NSDictionary class]]) return NO;
    NSMutableDictionary *updates = [NSMutableDictionary dictionary];
    for (id key in settings) {
        if (![key isKindOfClass:[NSString class]] || ![key length]) return NO;
        id value = SJGValidatedValue(key, settings[key]);
        if (!value) return NO;
        updates[key] = value;
    }
    NSString *path = SJGPreferencesPath();
    int lock = SJGLockSettings(path, NULL);
    if (lock < 0) return NO;
    NSError *error = nil;
    NSMutableDictionary *raw = [SJGMigrateSettingsLocked(path, &error) mutableCopy];
    BOOL ok = error == nil;
    if (ok) {
        [raw addEntriesFromDictionary:updates];
        ok = SJGAtomicWritePlist(raw, path, NULL);
    }
    SJGUnlockSettings(lock);
    if (ok) notify_post(SJG_SETTINGS_CHANGED);
    return ok;
}

/* Status is intentionally independent: never migrate it into user settings. */
static inline NSDictionary *SJGReadStatus(void) { return SJGReadPlist(SJGStatusPath()); }
static inline BOOL SJGWriteStatus(NSDictionary *status, NSError **error) {
    if (error) *error = nil;
    return SJGAtomicWritePlist(status, SJGStatusPath(), error);
}
#endif /* __OBJC__: compile helper as main.m and link Foundation. */
#endif
