// Tweak_Cyanide_Powercuff.x
// Ported from Cyanide powercuff - Thermal state simulation

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static BOOL g_cld_powercuffEnabled = NO;
static NSInteger g_cld_powercuffLevel = 0; // 0=off, 1=nominal, 2=light, 3=moderate, 4=heavy

%group PowercuffHooks

%hook CPMSHelper
+ (id)sharedInstance {
    CPMSHelper *helper = %orig;
    return helper;
}
%end

// Simulate thermal state through NSProcessInfo
%hook SBTelephonyManager
- (NSInteger)thermalState {
    if (g_cld_powercuffEnabled && g_cld_powercuffLevel > 1) {
        return g_cld_powercuffLevel; // Map to NSProcessInfoThermalState
    }
    return %orig;
}
%end

%end // PowercuffHooks

static void cld_loadPowercuffPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_powercuffEnabled = [prefs[@"cld_powercuffEnabled"] boolValue];
    g_cld_powercuffLevel = [prefs[@"cld_powercuffLevel"] integerValue];
    if (g_cld_powercuffEnabled) {
        %init(PowercuffHooks);
    }
}

static void cld_Powercuff_init(void) {
    cld_loadPowercuffPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadPowercuffPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
