#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import <notify.h>
#import <stdatomic.h>

static _Atomic(BOOL) SCCCRecording = false;
static void SCCCRecordingStateChanged(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef userInfo) {
    id v = SCReadPreferences()[@"Recording"];
    atomic_store(&SCCCRecording, v ? [v boolValue] : NO);
    SneakyCamCCVideo *module = (__bridge SneakyCamCCVideo *)o;
    if (module) [module refreshState];
}

// 拍照模块：点击触发一次拍照
@implementation SneakyCamCCPhoto
- (UIImage *)iconGlyph { return [UIImage systemImageNamed:@"camera"]; }
- (UIImage *)selectedIconGlyph { return [UIImage systemImageNamed:@"camera.fill"]; }
- (UIColor *)selectedColor { return [UIColor systemBlueColor]; }
- (BOOL)isActiveAllowed { id v=SCReadPreferences()[@"Enabled"]; return v?[v boolValue]:NO; }
- (void)setSelected:(BOOL)sel {
    [super setSelected:NO];
    if(sel && [self isActiveAllowed]) notify_post("com.spark.SneakyCam.takephoto");
}
@end

// 录像模块：点击切换录制，高亮表示正在录制
@implementation SneakyCamCCVideo
- (instancetype)init {
    self = [super init];
    if (self) {
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, (__bridge const void*)self, SCCCRecordingStateChanged, CFSTR("com.spark.SneakyCam.recordingstatechanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        id v = SCReadPreferences()[@"Recording"];
        atomic_store(&SCCCRecording, v ? [v boolValue] : NO);
    }
    return self;
}
- (UIImage *)iconGlyph { return [UIImage systemImageNamed:@"video"]; }
- (UIImage *)selectedIconGlyph { return [UIImage systemImageNamed:@"video.fill"]; }
- (UIColor *)selectedColor { return [UIColor systemRedColor]; }
- (BOOL)isActiveAllowed { id v=SCReadPreferences()[@"Enabled"]; return v?[v boolValue]:NO; }
- (BOOL)isSelected { return atomic_load(&SCCCRecording); }
- (void)setSelected:(BOOL)sel {
    if(sel && [self isActiveAllowed]) notify_post("com.spark.SneakyCam.startstopvideo");
}
- (void)refreshState {
    [super refreshState];
}
- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void*)self, CFSTR("com.spark.SneakyCam.recordingstatechanged"), NULL);
}
@end
