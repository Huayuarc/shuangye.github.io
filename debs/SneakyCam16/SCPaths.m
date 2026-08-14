#import "SCPaths.h"
#import <sys/stat.h>

static NSString * const SCDomain = @"com.spark.SneakyCam.plist";
static NSString * const SCAppGroups = @"/var/mobile/Containers/Shared/AppGroup";

static BOOL SCExists(NSString *p) { return [[NSFileManager defaultManager] fileExistsAtPath:p]; }
static NSDate *SCDate(NSString *p) { return [[[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil] fileModificationDate] ?: NSDate.distantPast; }

NSString *SCCurrentJailbreakRoot(void) {
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:SCAppGroups error:nil] ?: @[];
    NSString *best = nil; NSInteger scoreBest = -1; NSDate *dateBest = NSDate.distantPast;
    for (NSString *name in items) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *root = [SCAppGroups stringByAppendingPathComponent:name];
        NSInteger score = 0;
        if (SCExists([root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/SneakyCam16.dylib"])) score += 100;
        if (SCExists([root stringByAppendingPathComponent:@"Library/MobileSubstrate"])) score += 20;
        if (SCExists([root stringByAppendingPathComponent:@"usr/lib"])) score += 10;
        NSDate *d = SCDate(root);
        if (score > scoreBest || (score == scoreBest && [d compare:dateBest] == NSOrderedDescending)) { best=root; scoreBest=score; dateBest=d; }
    }
    if (best) return best;
    if (SCExists(@"/var/jb")) return @"/var/jb";
    return @"";
}

NSString *SCPreferencePath(void) {
    NSString *root = SCCurrentJailbreakRoot();
    return [root stringByAppendingPathComponent:[@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:SCDomain]];
}

void SCMigratePreferencesIfNeeded(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *current = SCPreferencePath();
    [fm createDirectoryAtPath:[current stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *candidates = [NSMutableArray arrayWithObjects:@"/var/mobile/Library/Preferences/com.spark.SneakyCam.plist", @"/var/jb/var/mobile/Library/Preferences/com.spark.SneakyCam.plist", nil];
    for (NSString *name in ([fm contentsOfDirectoryAtPath:SCAppGroups error:nil] ?: @[])) if ([name hasPrefix:@".jbroot-"]) [candidates addObject:[[SCAppGroups stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.spark.SneakyCam.plist"]];
    NSString *latest = SCExists(current) ? current : nil; NSDate *latestDate = latest ? SCDate(latest) : NSDate.distantPast;
    for (NSString *p in candidates) if (SCExists(p) && [SCDate(p) compare:latestDate] == NSOrderedDescending) { latest=p; latestDate=SCDate(p); }
    if (latest && ![latest isEqualToString:current]) { [fm removeItemAtPath:current error:nil]; [fm copyItemAtPath:latest toPath:current error:nil]; }
    if (SCExists(current)) for (NSString *p in candidates) if (![p isEqualToString:current]) [fm removeItemAtPath:p error:nil];
}

NSDictionary *SCReadPreferences(void) { SCMigratePreferencesIfNeeded(); return [NSDictionary dictionaryWithContentsOfFile:SCPreferencePath()] ?: @{}; }
void SCWritePreference(NSString *key, id value) { NSMutableDictionary *p=[SCReadPreferences() mutableCopy]; if(value)p[key]=value;else[p removeObjectForKey:key]; [p writeToFile:SCPreferencePath() atomically:YES]; }
