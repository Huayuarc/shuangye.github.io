#import <UIKit/UIKit.h>
#import "SCCaptureManager.h"
#import "SCPaths.h"

static NSTimeInterval SCUpTime=0, SCDownTime=0;

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

// 音量键视频/照片动作的 Darwin 广播
static void SCActionNotification(CFNotificationCenterRef c, void*o, CFStringRef n, const void*obj, CFDictionaryRef u) {
    if(!SCIsSpringBoard()) return;
    NSString *s=(__bridge NSString*)n;
    SCTrigger([s hasSuffix:@"startstopvideo"]);
}
// 关闭总开关时立即停止并释放相机
static void SCEnabledNotification(CFNotificationCenterRef c, void*o, CFStringRef n, const void*obj, CFDictionaryRef u) {
    if(!SCEnabled()) [[SCCaptureManager shared] stopAndRelease];
}

%hook SBVolumeControl
- (void)increaseVolume {
    %orig;
    NSDictionary *p=SCReadPreferences();
    if(!SCIsSpringBoard()||!SCEnabled()||![p[@"UseVolumeButtons"] ?: @YES boolValue]) return;
    NSTimeInterval t=[NSProcessInfo processInfo].systemUptime;
    if(t-SCUpTime<0.60) SCTrigger(YES);
    SCUpTime=t;
}
- (void)decreaseVolume {
    %orig;
    NSDictionary *p=SCReadPreferences();
    if(!SCIsSpringBoard()||!SCEnabled()||![p[@"UseVolumeButtons"] ?: @YES boolValue]) return;
    NSTimeInterval t=[NSProcessInfo processInfo].systemUptime;
    if(t-SCDownTime<0.60) SCTrigger(NO);
    SCDownTime=t;
}
%end

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
