#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import <notify.h>

static void SCVideoCCStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    SneakyCamCCVideo *module=(__bridge SneakyCamCCVideo *)observer;
    if(module) dispatch_async(dispatch_get_main_queue(), ^{ [module refreshState]; });
}

@implementation SneakyCamCCVideo
- (instancetype)init {
    self=[super init];
    if(self) CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, SCVideoCCStateChanged, CFSTR("com.spark.SneakyCam.recordingstatechanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    return self;
}
- (UIImage *)iconGlyph { return [UIImage systemImageNamed:@"video"]; }
- (UIImage *)selectedIconGlyph { return [UIImage systemImageNamed:@"video.fill"]; }
- (UIColor *)selectedColor { return [UIColor systemRedColor]; }
- (BOOL)isSelected { id v=SCReadPreferences()[@"Recording"]; return v?[v boolValue]:NO; }
- (void)setSelected:(BOOL)selected {
    id enabled=SCReadPreferences()[@"Enabled"];
    id video=SCReadPreferences()[@"VideoEnabled"];
    if((enabled?[enabled boolValue]:NO) && (video?[video boolValue]:YES))
        notify_post("com.spark.SneakyCam.startstopvideo");
    [self refreshState];
}
- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, CFSTR("com.spark.SneakyCam.recordingstatechanged"), NULL);
}
@end
