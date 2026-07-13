// Tweak_Cyanide_Nano.x
// Ported from Cyanide nano_registry - Apple Watch pairing compatibility

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static BOOL g_cld_nanoEnabled = NO;

%group NanoHooks

%hook NRDeviceManager
- (BOOL)isDeviceSupported:(id)device {
    if (g_cld_nanoEnabled) return YES;
    return %orig;
}
%end

%hook NRDevice
- (id)valueForProperty:(id)property {
    if (g_cld_nanoEnabled && [property isEqualToString:@"maxPairingCompatibilityVersion"]) {
        return @(999); // Allow any watch version
    }
    return %orig;
}
%end

%hook NRRegistry
- (BOOL)isKey:(id)key presentForDeviceID:(id)deviceID {
    if (g_cld_nanoEnabled) return YES;
    return %orig;
}
%end

%end // NanoHooks

static void cld_loadNanoPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_nanoEnabled = [prefs[@"cld_nanoEnabled"] boolValue];
    
    if (g_cld_nanoEnabled) {
        %init(NanoHooks);
    }
}

__attribute__((constructor)) static void cld_Nano_init(void) {
    cld_loadNanoPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadNanoPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
