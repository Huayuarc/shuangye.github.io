#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const EVDomain = @"com.cpdigitaldarkroom.itsevanesco";
static CFStringRef const EVNotify = CFSTR("com.cpdigitaldarkroom.itsevanesco.settings");

static NSString *EVPreferencesPath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *items = [fm contentsOfDirectoryAtPath:base error:nil] ?: @[];
    NSString *best = nil; NSDate *bestDate = nil;
    for (NSString *name in items) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *root = [base stringByAppendingPathComponent:name];
        NSString *dylib = [root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/EvanescoModern.dylib"];
        NSString *marker = [root stringByAppendingPathComponent:@"Library/MobileSubstrate"];
        if (![fm fileExistsAtPath:dylib] && ![fm fileExistsAtPath:marker]) continue;
        NSDate *date = [[fm attributesOfItemAtPath:root error:nil] fileModificationDate];
        if (!best || (date && [date compare:bestDate] == NSOrderedDescending)) { best = root; bestDate = date; }
    }
    NSString *prefs = @"var/mobile/Library/Preferences/com.cpdigitaldarkroom.itsevanesco.plist";
    return best ? [best stringByAppendingPathComponent:prefs] : @"/var/mobile/Library/Preferences/com.cpdigitaldarkroom.itsevanesco.plist";
}

static NSMutableDictionary *EVReadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:EVPreferencesPath()];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}
static id EVValue(NSString *key, id fallback) { id v = EVReadPrefs()[key]; return v ?: fallback; }
static void EVSetValue(NSString *key, id value) {
    NSString *path = EVPreferencesPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *d = EVReadPrefs(); if (value) d[key] = value; else [d removeObjectForKey:key];
    [d writeToFile:path atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), EVNotify, NULL, NULL, true);
}
