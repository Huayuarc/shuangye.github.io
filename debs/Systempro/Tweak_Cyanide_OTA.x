// Tweak_Cyanide_OTA.x
// Ported from Cyanide darksword_ota - Disable OTA software updates
// Adapted for jailbreak: uses preferences and NSUserDefaults instead of KRW

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>

static BOOL g_cld_otaEnabled = NO;

@interface _CLDOTAHelper : NSObject
@end
@implementation _CLDOTAHelper
+ (void)cld_ota_disable:(BOOL)disable {
    if (disable) {
        // Mark OTA daemons as disabled via user defaults
        // These are read by the system to determine if OTA should run
        
        // Write to the OTA preference files
        NSDictionary *otas = @{
            @"com.apple.mobile.softwareupdated": @YES,
            @"com.apple.OTATaskingAgent": @YES,
            @"com.apple.softwareupdateservicesd": @YES,
        };
        
        // Use xpcplist-style approach: set the disabled flags
        NSString *plistPath = @"/var/db/com.apple.xpc.launchd/disabled.plist";
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
        if (!plist) plist = [NSMutableDictionary dictionary];
        
        BOOL changed = NO;
        for (NSString *key in otas) {
            if (![plist[key] boolValue]) {
                plist[key] = @YES;
                changed = YES;
            }
        }
        
        if (changed) {
            [plist writeToFile:plistPath atomically:YES];
        }
        
        // Post notification to trigger OTA preference refresh
        notify_post("com.apple.mobile.softwareupdated.SUPreferencesChangedNotification");
        
    } else {
        // Re-enable: remove from disabled plist
        NSString *plistPath = @"/var/db/com.apple.xpc.launchd/disabled.plist";
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
        if (plist) {
            BOOL changed = NO;
            if (plist[@"com.apple.mobile.softwareupdated"]) {
                [plist removeObjectForKey:@"com.apple.mobile.softwareupdated"];
                changed = YES;
            }
            if (plist[@"com.apple.OTATaskingAgent"]) {
                [plist removeObjectForKey:@"com.apple.OTATaskingAgent"];
                changed = YES;
            }
            if (plist[@"com.apple.softwareupdateservicesd"]) {
                [plist removeObjectForKey:@"com.apple.softwareupdateservicesd"];
                changed = YES;
            }
            if (changed) {
                [plist writeToFile:plistPath atomically:YES];
            }
        }
    }
}
@end

%group OTAHooks
%end // OTAHooks

static void cld_loadOTAPrefs() {
    BOOL wasEnabled = g_cld_otaEnabled;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_otaEnabled = [prefs[@"cld_otaEnabled"] boolValue];
    
    if (g_cld_otaEnabled != wasEnabled) {
        [_CLDOTAHelper cld_ota_disable:g_cld_otaEnabled];
    }
}

__attribute__((constructor)) static void cld_OTA_init(void) {
    cld_loadOTAPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadOTAPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
