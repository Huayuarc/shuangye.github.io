// Tweak_Cyanide_SnowBoard.x
// Ported from Cyanide snowboardlite + themer - Icon theme engine

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static BOOL g_cld_snowboardEnabled = NO;
static NSString *g_cld_snowboardThemePath = nil;
static NSCache *g_cld_snowboardImageCache = nil;
static NSDictionary *g_cld_snowboardThemeMap = nil; // bundleID -> icon path

@protocol SnowBoardIcon <NSObject>
- (NSString *)applicationBundleID;
- (NSString *)bundleIdentifier;
@end

@interface SBIconView : UIView
- (UIImage *_Nullable)cld_themedImage;
@end

%group SnowBoardHooks

%hook SBIconView

- (UIImage *_Nullable)cld_themedImage {
    if (!g_cld_snowboardEnabled) return nil;

    // Get the bundle identifier from the icon
    id<SnowBoardIcon> icon = [(id)self valueForKey:@"_icon"];
    if (!icon) return nil;
    
    NSString *bundleID = nil;
    if ([icon respondsToSelector:@selector(applicationBundleID)]) {
        bundleID = [icon applicationBundleID];
    } else if ([icon respondsToSelector:@selector(bundleIdentifier)]) {
        bundleID = [icon bundleIdentifier];
    }
    
    if (!bundleID || !g_cld_snowboardThemeMap[bundleID]) return nil;
    
    // Check cache
    UIImage *cached = [g_cld_snowboardImageCache objectForKey:bundleID];
    if (cached) return cached;
    
    // Load and cache
    NSString *iconPath = g_cld_snowboardThemeMap[bundleID];
    UIImage *image = [UIImage imageWithContentsOfFile:iconPath];
    if (image) {
        [g_cld_snowboardImageCache setObject:image forKey:bundleID];
    }
    return image;
}

- (UIImage *)iconImage {
    UIImage *themed = [(id)self cld_themedImage];
    if (themed) return themed;
    return %orig;
}

- (UIImage *)displayedImage {
    UIImage *themed = [(id)self cld_themedImage];
    if (themed) return themed;
    return %orig;
}

%end

%end // SnowBoardHooks

static void cld_snowboard_load_theme(NSString *themePath) {
    if (!themePath.length) {
        g_cld_snowboardThemeMap = nil;
        return;
    }
    
    // Look for Icons directory in theme
    NSString *iconsDir = [themePath stringByAppendingPathComponent:@"Icons"];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:iconsDir isDirectory:&isDir] || !isDir) {
        iconsDir = themePath;
    }
    
    // Scan for PNG files and map them to bundle IDs
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSArray *files = [fm contentsOfDirectoryAtPath:iconsDir error:nil];
    for (NSString *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
        NSString *bundleID = [file stringByDeletingPathExtension];
        NSString *fullPath = [iconsDir stringByAppendingPathComponent:file];
        map[bundleID] = fullPath;
    }
    
    g_cld_snowboardThemeMap = [map copy];
    
    // Initialize cache
    if (!g_cld_snowboardImageCache) {
        g_cld_snowboardImageCache = [[NSCache alloc] init];
        g_cld_snowboardImageCache.countLimit = 100;
        g_cld_snowboardImageCache.totalCostLimit = 10 * 1024 * 1024; // 10MB
    }
}

static void cld_loadSnowBoardPrefs() {
    NSString *oldPath = g_cld_snowboardThemePath;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_snowboardEnabled = [prefs[@"cld_snowboardEnabled"] boolValue];
    g_cld_snowboardThemePath = prefs[@"cld_snowboardThemePath"];
    
    if (g_cld_snowboardEnabled && g_cld_snowboardThemePath.length > 0) {
        if (![g_cld_snowboardThemePath isEqualToString:oldPath]) {
            cld_snowboard_load_theme(g_cld_snowboardThemePath);
        }
        %init(SnowBoardHooks);
        [g_cld_snowboardImageCache removeAllObjects];
    }
}

static void cld_SnowBoard_init(void) {
    cld_loadSnowBoardPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadSnowBoardPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

__attribute__((constructor)) static void cld_snowboard_ctor(void) {
    cld_SnowBoard_init();
}
