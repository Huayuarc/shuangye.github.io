// Tweak_Cyanide_KillAll.x
// Ported from Cyanide killallapps - Kill all background apps

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface SBDisplayItem : NSObject
- (NSString *)bundleIdentifier;
@end

@interface SBAppSwitcherModel : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)allDisplayItems;
- (void)removeDisplayItem:(SBDisplayItem *)item;
- (void)save;
@end

static BOOL g_cld_killAllEnabled = NO;

%group KillAllHooks

%hook SBWorkspace
- (void)killAllApps {
    // Get SBAppLayout from running apps
    %orig;
}
%end

// Hook SBMainSwitcherViewController to add kill-all button or gesture
%hook SBMainSwitcherViewController

- (void)_killAllApps {
    // Get all display items
    SBAppSwitcherModel *appSwitcherModel = [objc_getClass("SBAppSwitcherModel") sharedInstance];
    NSArray *items = [appSwitcherModel allDisplayItems];
    
    NSArray *bundleBlacklist = @[
        @"com.opa334.santander",
        @"com.opa334.trollstore",
        @"com.apple.springboard",
        @"com.apple.backboardd",
        @"com.apple.PineBoard",
        @"com.apple.InCallService",
    ];
    
    for (SBDisplayItem *item in items) {
        NSString *bundleID = [item bundleIdentifier];
        if (!bundleID) continue;
        
        BOOL skip = NO;
        for (NSString *blacklisted in bundleBlacklist) {
            if ([bundleID isEqualToString:blacklisted]) {
                skip = YES;
                break;
            }
        }
        if (skip) continue;
        
        [appSwitcherModel removeDisplayItem:item];
    }
    [appSwitcherModel save];
}

%end

%end // KillAllHooks

static void cld_loadKillAllPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    BOOL enabled = [prefs[@"cld_killAllApps"] boolValue];
    if (enabled != g_cld_killAllEnabled) {
        g_cld_killAllEnabled = enabled;
        if (enabled) {
            %init(KillAllHooks);
        }
    }
}

static void cld_KillAll_init(void) {
    cld_loadKillAllPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadKillAllPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
