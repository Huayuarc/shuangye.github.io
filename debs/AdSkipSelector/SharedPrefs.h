#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const ASPDomain = @"com.huayuarc.adskipselector";
static NSString * const ASPChanged = @"com.huayuarc.adskipselector/preferences-changed";

static NSString *ASPPreferencesPath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *items = [fm contentsOfDirectoryAtPath:base error:nil] ?: @[];
    NSString *best = nil; NSDate *bestDate = nil; NSInteger bestScore = -1;
    for (NSString *name in items) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *root = [base stringByAppendingPathComponent:name];
        NSInteger score = 0;
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/AdSkipSelector.dylib"]]) score += 100;
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library/MobileSubstrate"]]) score += 10;
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"usr/lib"]]) score += 5;
        if (!score) continue;
        NSDate *date = [[fm attributesOfItemAtPath:root error:nil] fileModificationDate] ?: NSDate.distantPast;
        if (score > bestScore || (score == bestScore && [date compare:bestDate] == NSOrderedDescending)) {
            best = root; bestDate = date; bestScore = score;
        }
    }
    NSString *prefs = best ? [best stringByAppendingPathComponent:@"var/mobile/Library/Preferences"] : @"/var/mobile/Library/Preferences";
    return [prefs stringByAppendingPathComponent:[ASPDomain stringByAppendingString:@".plist"]];
}

static NSMutableDictionary *ASPLoadPreferences(void) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:ASPPreferencesPath()];
    return dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

static NSSet<NSString *> *ASPEnabledBundleIDs(void) {
    NSArray *ids = ASPLoadPreferences()[@"EnabledBundleIDs"];
    return [ids isKindOfClass:NSArray.class] ? [NSSet setWithArray:ids] : [NSSet set];
}

static __attribute__((unused)) BOOL ASPSaveEnabledBundleIDs(NSSet<NSString *> *ids) {
    NSString *path = ASPPreferencesPath();
    NSString *dir = path.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *dict = ASPLoadPreferences();
    dict[@"EnabledBundleIDs"] = [[ids allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    BOOL ok = [dict writeToFile:path atomically:YES];
    if (ok) CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)ASPChanged, NULL, NULL, true);
    return ok;
}
