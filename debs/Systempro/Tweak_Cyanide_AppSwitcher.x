// Tweak_Cyanide_AppSwitcher.x
// Ported from Cyanide appswitchergrid - Grid App Switcher (3-column layout)

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static BOOL g_cld_appSwitcherGridEnabled = NO;

%group AppSwitcherGridHooks

%hook SBAppSwitcherSettings

- (long long)switcherStyle {
    return 2; // Grid style (0=stack, 1=column, 2=grid)
}

%end

%hook SBDeckSwitcherModifier

- (long long)dockUpdateMode {
    return 2; // Grid dock mode
}

%end

%end // AppSwitcherGridHooks

static void cld_loadAppSwitcherPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    BOOL enabled = [prefs[@"cld_appSwitcherGrid"] boolValue];
    if (enabled != g_cld_appSwitcherGridEnabled) {
        g_cld_appSwitcherGridEnabled = enabled;
        if (enabled) {
            %init(AppSwitcherGridHooks);
        }
    }
}

static void cld_AppSwitcher_init(void) {
    cld_loadAppSwitcherPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadAppSwitcherPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
