// Tweak_Cyanide_Layout.x
// Ported from Cyanide darksword_layout - Home screen icon spacing and zoom

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static BOOL g_cld_layoutEnabled = NO;
static CGFloat g_cld_extraLeft = 0;
static CGFloat g_cld_extraRight = 0;
static CGFloat g_cld_extraTop = 0;
static CGFloat g_cld_extraBottom = 0;
static CGFloat g_cld_dockExtraH = 0;
static CGFloat g_cld_homeScale = 1.0;
static CGFloat g_cld_dockScale = 1.0;

// SBIconImageInfo 完整定义（私有框架，需手动声明）
struct SBIconImageInfo {
    CGSize size;
    CGFloat cornerRadius;
    CGFloat continuousCornerRadius;
};

@protocol SBIconView
- (BOOL)isDock;
@end

%group LayoutHooks

%hook SBIconListLayout
- (struct UIEdgeInsets)portraitLayoutInsets {
    struct UIEdgeInsets insets = %orig;
    if (g_cld_layoutEnabled) {
        insets.top += g_cld_extraTop;
        insets.left += g_cld_extraLeft;
        insets.bottom += g_cld_extraBottom;
        insets.right += g_cld_extraRight;
    }
    return insets;
}
%end

%hook SBIconView
- (struct SBIconImageInfo)iconImageInfo {
    struct SBIconImageInfo info = %orig;
    if (g_cld_layoutEnabled) {
        if ([(id<SBIconView>)self isDock]) {
            if (g_cld_dockScale != 1.0) {
                info.size.width *= g_cld_dockScale;
                info.size.height *= g_cld_dockScale;
                info.cornerRadius *= g_cld_dockScale;
            }
        } else {
            if (g_cld_homeScale != 1.0) {
                info.size.width *= g_cld_homeScale;
                info.size.height *= g_cld_homeScale;
                info.cornerRadius *= g_cld_homeScale;
            }
        }
    }
    return info;
}
%end

%end // LayoutHooks

static void cld_loadLayoutPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_layoutEnabled = [prefs[@"cld_layoutEnabled"] boolValue];
    g_cld_extraLeft = [prefs[@"cld_layoutExtraLeft"] floatValue];
    g_cld_extraRight = [prefs[@"cld_layoutExtraRight"] floatValue];
    g_cld_extraTop = [prefs[@"cld_layoutExtraTop"] floatValue];
    g_cld_extraBottom = [prefs[@"cld_layoutExtraBottom"] floatValue];
    g_cld_dockExtraH = [prefs[@"cld_layoutDockExtraH"] floatValue];
    g_cld_homeScale = [prefs[@"cld_layoutHomeScale"] floatValue];
    if (g_cld_homeScale <= 0) g_cld_homeScale = 1.0;
    g_cld_dockScale = [prefs[@"cld_layoutDockScale"] floatValue];
    if (g_cld_dockScale <= 0) g_cld_dockScale = 1.0;
    if (g_cld_layoutEnabled) {
        %init(LayoutHooks);
    }
}

static void cld_Layout_init(void) {
    cld_loadLayoutPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadLayoutPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
