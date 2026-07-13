// Tweak_Cyanide_AxonLite.x
// Ported from Cyanide axonlite - Unified notification badge grouping

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static BOOL g_cld_axonliteEnabled = NO;
static BOOL g_cld_axonliteShowCount = YES;
static BOOL g_cld_axonliteFilterDuplicates = NO;

@protocol AxonLiteIcon <NSObject>
- (NSString *)applicationBundleID;
@end

%group AxonLiteHooks

%hook SBIconBadgeView

- (void)setBadgeValue:(id)value {
    if (!g_cld_axonliteEnabled) {
        %orig;
        return;
    }
    
    // Override: aggregate all badges into one unified count
    if (g_cld_axonliteShowCount) {
        // Get total badge count from all icons
        static int totalBadgeCount = 0;
        
        id<AxonLiteIcon> icon = [(id)self valueForKey:@"_icon"];
        if (icon) {
            NSString *bundleID = nil;
            if ([icon respondsToSelector:@selector(applicationBundleID)]) {
                bundleID = [icon applicationBundleID];
            }
            
            if (bundleID) {
                // Track individual badge counts
                static NSMutableDictionary *badgeCounts = nil;
                if (!badgeCounts) badgeCounts = [NSMutableDictionary dictionary];
                
                int count = [value intValue];
                if (count > 0) {
                    badgeCounts[bundleID] = @(count);
                } else {
                    [badgeCounts removeObjectForKey:bundleID];
                }
                
                // Calculate total
                totalBadgeCount = 0;
                for (NSNumber *num in badgeCounts.allValues) {
                    totalBadgeCount += [num intValue];
                }
                
                // Show total on the first app or as a separate badge
                if (totalBadgeCount > 0) {
                    %orig([NSString stringWithFormat:@"%d", totalBadgeCount]);
                    return;
                }
            }
        }
    }
    
    %orig;
}

%end

%end // AxonLiteHooks

static void cld_loadAxonLitePrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_axonliteEnabled = [prefs[@"cld_axonliteEnabled"] boolValue];
    g_cld_axonliteShowCount = [prefs[@"cld_axonliteShowCount"] boolValue];
    g_cld_axonliteFilterDuplicates = [prefs[@"cld_axonliteFilterDuplicates"] boolValue];
    
    if (g_cld_axonliteEnabled) {
        %init(AxonLiteHooks);
    }
}

__attribute__((constructor)) static void cld_AxonLite_init(void) {
    cld_loadAxonLitePrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadAxonLitePrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
