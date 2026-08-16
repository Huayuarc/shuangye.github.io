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

static void SCTrigger(BOOL video) {
    if(!SCEnabled()) return;
    SCCaptureManager *m=[SCCaptureManager shared];
    if(video) [m toggleVideo]; else [m takePhoto];
    // 触觉由实际捕获成功回调产生，避免初始化失败仍误报已执行。
}

// 音量按键归口：兼容不同 iOS 的多个入口。
// 同一物理按键会在极短时间内产生多个 selector 回调，仅过滤 55ms 内重复；
// 真实双击支持约 70–650ms，触发后清空状态避免三击重复。
static void SCPress(BOOL up, NSTimeInterval now) {
    NSTimeInterval lastHandled = up?SCUpHandled:SCDownHandled;
    if (now-lastHandled < 0.055) return;
    if (up) SCUpHandled=now; else SCDownHandled=now;

    NSTimeInterval last = up?SCUpTime:SCDownTime;
    NSTimeInterval interval = now-last;
    BOOL isDouble = (last>0 && interval>=0.07 && interval<=0.65);
    if (isDouble) {
        if (up) SCUpTime=0; else SCDownTime=0;
    } else {
        if (up) SCUpTime=now; else SCDownTime=now;
    }

    NSDictionary *p=SCReadPreferences();
    if(!SCIsSpringBoard()||!SCEnabled()||![p[@"UseVolumeButtons"] ?: @YES boolValue]) return;
    if (!isDouble) return;
    NSString *action = up ? p[@"VolumeUpAction"] : p[@"VolumeDownAction"];
    if (![action isKindOfClass:[NSString class]] || action.length==0) action = up?@"video":@"photo";
    if ([action isEqualToString:@"video"]) SCTrigger(YES);
    else if ([action isEqualToString:@"photo"]) SCTrigger(NO);
    // off 或未知值不执行
}

%hook SBVolumeControl
- (void)increaseVolume { %orig; SCPress(YES, [NSProcessInfo processInfo].systemUptime); }
- (void)increaseVolumePressed { %orig; SCPress(YES, [NSProcessInfo processInfo].systemUptime); }
- (void)decreaseVolume { %orig; SCPress(NO, [NSProcessInfo processInfo].systemUptime); }
- (void)decreaseVolumePressed { %orig; SCPress(NO, [NSProcessInfo processInfo].systemUptime); }
// iOS 17 及部分版本使用的新按键入口
- (void)volumeIncreasePressDownWithModifiers:(id)modifiers { %orig; SCPress(YES, [NSProcessInfo processInfo].systemUptime); }
- (void)volumeDecreasePressDownWithModifiers:(id)modifiers { %orig; SCPress(NO, [NSProcessInfo processInfo].systemUptime); }
- (void)volumeUpPressed { %orig; SCPress(YES, [NSProcessInfo processInfo].systemUptime); }
- (void)volumeDownPressed { %orig; SCPress(NO, [NSProcessInfo processInfo].systemUptime); }
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
