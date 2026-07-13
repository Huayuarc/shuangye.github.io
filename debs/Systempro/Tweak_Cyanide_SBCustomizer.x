// Tweak_Cyanide_SBCustomizer.x
// Ported from Cyanide sbcustomizer - Home screen grid customization

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static BOOL g_cld_sbCustomizerEnabled = NO;
static int g_cld_sbDockIcons = 4;
static int g_cld_sbCols = 4;
static int g_cld_sbRows = 6;
static BOOL g_cld_sbHideLabels = NO;

@protocol SBIconListLayout
- (BOOL)isDock;
@end

%group SBCustomizerHooks

%hook SBIconListLayout
- (long long)numberOfPortraitColumns {
    if (g_cld_sbCustomizerEnabled && ![(id<SBIconListLayout>)self isDock]) {
        return g_cld_sbCols;
    }
    return %orig;
}

- (long long)numberOfPortraitRows {
    if (g_cld_sbCustomizerEnabled && ![(id<SBIconListLayout>)self isDock]) {
        return g_cld_sbRows;
    }
    return %orig;
}
%end

%hook SBDockIconListLayout
- (long long)numberOfPortraitColumns {
    if (g_cld_sbCustomizerEnabled) {
        return g_cld_sbDockIcons;
    }
    return %orig;
}
%end

%hook SBIconView
- (BOOL)isLabelHidden {
    if (g_cld_sbCustomizerEnabled && g_cld_sbHideLabels) return YES;
    return %orig;
}
%end

%end // SBCustomizerHooks

static void cld_loadSBCustomizerPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_sbCustomizerEnabled = [prefs[@"cld_sbCustomizerEnabled"] boolValue];
    g_cld_sbDockIcons = (int)[prefs[@"cld_sbDockIcons"] integerValue];
    if (g_cld_sbDockIcons < 4) g_cld_sbDockIcons = 4;
    if (g_cld_sbDockIcons > 7) g_cld_sbDockIcons = 7;
    g_cld_sbCols = (int)[prefs[@"cld_sbCols"] integerValue];
    if (g_cld_sbCols < 3) g_cld_sbCols = 3;
    if (g_cld_sbCols > 7) g_cld_sbCols = 7;
    g_cld_sbRows = (int)[prefs[@"cld_sbRows"] integerValue];
    if (g_cld_sbRows < 4) g_cld_sbRows = 4;
    if (g_cld_sbRows > 8) g_cld_sbRows = 8;
    g_cld_sbHideLabels = [prefs[@"cld_sbHideLabels"] boolValue];
    if (g_cld_sbCustomizerEnabled) {
        %init(SBCustomizerHooks);
    }
}

static void cld_SBCustomizer_init(void) {
    cld_loadSBCustomizerPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadSBCustomizerPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
