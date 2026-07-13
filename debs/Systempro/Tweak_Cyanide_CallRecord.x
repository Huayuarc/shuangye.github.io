// Tweak_Cyanide_CallRecord.x
// Ported from Cyanide call_recording_sound - Mute call recording disclosure beep

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

static BOOL g_cld_callRecordMute = NO;

%group CallRecordHooks

%hook TUAudioController
- (BOOL)shouldPlayRecordingTone {
    if (g_cld_callRecordMute) return NO;
    return %orig;
}
%end

%end // CallRecordHooks

static void cld_loadCallRecordPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    BOOL enabled = [prefs[@"cld_callRecordMute"] boolValue];
    if (enabled != g_cld_callRecordMute) {
        g_cld_callRecordMute = enabled;
        if (enabled) {
            %init(CallRecordHooks);
        }
    }
}

static void cld_CallRecord_init(void) {
    cld_loadCallRecordPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadCallRecordPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
