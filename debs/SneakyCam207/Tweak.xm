#import <UIKit/UIKit.h>
#import "SCCaptureManager.h"
#import "SCPaths.h"

static NSTimeInterval SCUpTime=0, SCDownTime=0;
static NSTimeInterval SCUpHandled=0, SCDownHandled=0; // 同一按键多入口防重复

// 单一相机所有者：仅在 SpringBoard 宿主中执行捕获，避免多进程各自建会话。
static BOOL SCIsSpringBoard(void) {
    NSString *proc=[[NSProcessInfo processInfo] processName];
    return [proc isEqualToString:@"SpringBoard"];
}
static BOOL SCEnabled(void) { id v=SCReadPreferences()[@"Enabled"]; return v?[v boolValue]:NO; }
static BOOL SCHapticsEnabled(void) { id v=SCReadPreferences()[@"HapticFeedback"]; return v?[v boolValue]:YES; }

static void SCHaptics(void) {
    if(!SCHapticsEnabled()) return;
    UIImpactFeedbackGenerator *g=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [g prepare];
    [g impactOccurred];
}

static void SCTrigger(BOOL video) {
    if(!SCEnabled()) return;
    SCCaptureManager *m=[SCCaptureManager shared];
    if(video) [m toggleVideo]; else [m takePhoto];
    SCHaptics();
}

// 音量按键归口：兼容不同 iOS 的 increaseVolume / increaseVolumePressed 等多个入口，
// 同一物理按键的多入口只计一次（250ms 防重）。
static void SCPress(BOOL up, NSTimeInterval now) {
    NSTimeInterval lastHandled = up?SCUpHandled:SCDownHandled;
    if (now-lastHandled < 0.25) return; // 同一次按键的事件链防重复
    if (up) SCUpHandled=now; else SCDownHandled=now;

    NSTimeInterval last = up?SCUpTime:SCDownTime;
    BOOL isDouble = (now-last < 0.60);
    if (up) SCUpTime=now; else SCDownTime=now;

    NSDictionary *p=SCReadPreferences();
    if(!SCIsSpringBoard()||!SCEnabled()||![p[@"UseVolumeButtons"] ?: @YES boolValue]) return;
    if (isDouble) SCTrigger(up);
}

%hook SBVolumeControl
- (void)increaseVolume { %orig; SCPress(YES, [NSProcessInfo processInfo].systemUptime); }
- (void)increaseVolumePressed { %orig; SCPress(YES, [NSProcessInfo processInfo].systemUptime); }
- (void)decreaseVolume { %orig; SCPress(NO, [NSProcessInfo processInfo].systemUptime); }
- (void)decreaseVolumePressed { %orig; SCPress(NO, [NSProcessInfo processInfo].systemUptime); }
%end

// 音量键动作的 Darwin 广播
static void SCActionNotification(CFNotificationCenterRef c, void*o, CFStringRef n, const void*obj, CFDictionaryRef u) {
    if(!SCIsSpringBoard()) return;
    NSString *s=(__bridge NSString*)n;
    SCTrigger([s hasSuffix:@"startstopvideo"]);
}
// 关闭总开关时立即停止并释放相机
static void SCEnabledNotification(CFNotificationCenterRef c, void*o, CFStringRef n, const void*obj, CFDictionaryRef u) {
    if(!SCEnabled()) [[SCCaptureManager shared] stopAndRelease];
}

%ctor {
    @autoreleasepool {
        SCMigratePreferencesIfNeeded();
        CFNotificationCenterRef dc=CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc,NULL,SCActionNotification,CFSTR("com.spark.SneakyCam.takephoto"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc,NULL,SCActionNotification,CFSTR("com.spark.SneakyCam.startstopvideo"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc,NULL,SCEnabledNotification,CFSTR("com.spark.SneakyCam.enabledchanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        if(!SCEnabled()) [[SCCaptureManager shared] stopAndRelease];
    }
}
