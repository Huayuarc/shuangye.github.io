#import "H120Preferences.h"
#import <CoreFoundation/CoreFoundation.h>
#include <notify.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <dlfcn.h>
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
#include <roothide.h>
#else
#include <rootless.h>
#endif

NSString * const H120PreferencesDomain = @"cn.zqbb.fix120hz";
NSString * const H120PreferencesNotification = @"cn.zqbb.hello.120hz.notif";

NSString *H120JailbreakPath(NSString *logicalPath) {
    if (![logicalPath hasPrefix:@"/"] || [logicalPath containsString:@"/../"]) return nil;
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    NSString *resolved = jbroot(logicalPath);
#else
    NSString *resolved = ROOT_PATH_NS_VAR(logicalPath);
#endif
    if (!resolved.length || [resolved isEqualToString:logicalPath]) return nil;
    return resolved;
}

NSString *H120PreferencesPath(void) {
    return H120JailbreakPath(@"/var/mobile/Library/Preferences/cn.zqbb.fix120hz.plist");
}

NSDictionary *H120ReadPreferences(void) {
    NSString *path = H120PreferencesPath();
    if (!path) return @{};
    id value = [NSDictionary dictionaryWithContentsOfFile:path];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static BOOL H120UpdatePreferences(NSDictionary *replacement, NSString *key, id value) {
    NSString *path = H120PreferencesPath();
    if (!path) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    NSString *lockPath = [path stringByAppendingString:@".lock"];
    int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (fd < 0) return NO;
    if (flock(fd, LOCK_EX) != 0) { close(fd); return NO; }
    NSMutableDictionary *preferences = replacement ? replacement.mutableCopy : H120ReadPreferences().mutableCopy;
    if (key) {
        if (value) preferences[key] = value;
        else [preferences removeObjectForKey:key];
    }
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:preferences
                  format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    BOOL success = data && [data writeToFile:path options:NSDataWritingAtomic error:&error];
    flock(fd, LOCK_UN);
    close(fd);
    if (success) H120PostPreferencesChanged();
    return success;
}

BOOL H120WritePreference(NSString *key, id value) {
    if (!key.length) return NO;
    return H120UpdatePreferences(nil, key, value);
}

BOOL H120ReplacePreferences(NSDictionary *preferences) {
    if (![preferences isKindOfClass:NSDictionary.class] ||
        ![NSPropertyListSerialization propertyList:preferences isValidForFormat:NSPropertyListBinaryFormat_v1_0]) return NO;
    return H120UpdatePreferences(preferences, nil, nil);
}

void H120PostPreferencesChanged(void) {
    notify_post(H120PreferencesNotification.UTF8String);
    CFNotificationCenterRef center = H120DistributedNotificationCenter();
    if (center) {
        id rate = H120ReadPreferences()[@"wantsFPS"] ?: @120;
        NSDictionary *info = @{@"action": @"rate", @"newRate": rate};
        CFNotificationCenterPostNotification(center, (__bridge CFStringRef)H120PreferencesNotification,
                                             NULL, (__bridge CFDictionaryRef)info, true);
    }
}

CFNotificationCenterRef H120DistributedNotificationCenter(void) {

    typedef CFNotificationCenterRef (*GetCenter)(void);
    static GetCenter getCenter = (GetCenter)dlsym(RTLD_DEFAULT, "CFNotificationCenterGetDistributedCenter");
    return getCenter ? getCenter() : NULL;
}
