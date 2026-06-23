#import <Foundation/Foundation.h>

static NSString * const AKRPrefsDomain = @"com.huayuarc.akaraprefs";
static NSString * const AKRPrefsChangedNotification = @"com.huayuarc.akaraprefs/prefsChanged";

static inline NSString *AKRRootlessPrefix(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ? @"/var/jb" : @"";
}

static inline NSString *AKRPathInPrefix(NSString *path) {
    if ([path hasPrefix:@"/var/jb/"] || AKRRootlessPrefix().length == 0) {
        return path;
    }
    return [AKRRootlessPrefix() stringByAppendingString:path];
}

static inline NSString *AKRMobilePath(NSString *relativePath) {
    NSString *mobileRoot = AKRRootlessPrefix().length > 0 ? @"/var/jb/var/mobile" : @"/var/mobile";
    return [mobileRoot stringByAppendingPathComponent:relativePath];
}

static inline NSString *AKRPrefsPathForDomain(NSString *domain) {
    return AKRMobilePath([NSString stringWithFormat:@"Library/Preferences/%@.plist", domain]);
}

static inline NSArray<NSString *> *AKRPrefsPathsForDomain(NSString *domain) {
    NSString *relativePath = [NSString stringWithFormat:@"Library/Preferences/%@.plist", domain];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:[@"/var/mobile" stringByAppendingPathComponent:relativePath]];
    NSString *activePath = AKRPrefsPathForDomain(domain);
    if (![paths containsObject:activePath]) {
        [paths addObject:activePath];
    }
    return paths;
}

static inline NSDictionary *AKRPreferencesForDomain(NSString *domain) {
    NSMutableDictionary *preferences = [NSMutableDictionary dictionary];
    for (NSString *path in AKRPrefsPathsForDomain(domain)) {
        NSDictionary *filePreferences = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([filePreferences isKindOfClass:NSDictionary.class]) {
            [preferences addEntriesFromDictionary:filePreferences];
        }
    }
    return preferences;
}

static inline NSDictionary *AKRPreferences(void) {
    return AKRPreferencesForDomain(AKRPrefsDomain);
}

static inline id AKRPreferenceValue(NSArray<NSString *> *keys) {
    NSDictionary *preferences = AKRPreferences();
    for (NSString *key in keys) {
        id value = preferences[key];
        if (value) {
            return value;
        }
    }
    return nil;
}

static inline BOOL AKRPreferenceBool(NSArray<NSString *> *keys, BOOL defaultValue) {
    id value = AKRPreferenceValue(keys);
    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return defaultValue;
}

static inline CGFloat AKRPreferenceCGFloat(NSArray<NSString *> *keys, CGFloat defaultValue) {
    id value = AKRPreferenceValue(keys);
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return (CGFloat)[value doubleValue];
    }
    return defaultValue;
}

static inline NSInteger AKRPreferenceInteger(NSArray<NSString *> *keys, NSInteger defaultValue) {
    id value = AKRPreferenceValue(keys);
    if ([value respondsToSelector:@selector(integerValue)]) {
        return [value integerValue];
    }
    return defaultValue;
}

static inline void AKRPostDarwinNotification(NSString *notificationName) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)notificationName, NULL, NULL, YES);
}

static inline void AKRPostPrefsChanged(void) {
    AKRPostDarwinNotification(AKRPrefsChangedNotification);
}
