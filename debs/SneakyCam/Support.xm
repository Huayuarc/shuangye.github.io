#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "SCPaths.h"

static BOOL SCKeepLockRecording(void){ id v=SCReadPreferences()[@"LockScreenKeepRecording"]; return v?[v boolValue]:YES; }

static NSString *SCMonitorApplicationID(id object){
    for(NSString *name in @[@"applicationID",@"clientApplicationID",@"bundleID",@"bundleIdentifier"]){SEL sel=NSSelectorFromString(name);if([object respondsToSelector:sel]){id value=((id(*)(id,SEL))objc_msgSend)(object,sel);if([value isKindOfClass:NSString.class]&&[value length])return value;}}
    return nil;
}
static BOOL SCIsSpringBoardCaptureClient(id object){
    NSString *app=SCMonitorApplicationID(object);
    if([app isEqualToString:@"com.apple.springboard"]||[app caseInsensitiveCompare:@"SpringBoard"]==NSOrderedSame)return YES;
    NSString *proc=NSProcessInfo.processInfo.processName;
    // 部分 iOS 17 客户端对象不再公开 applicationID；在 SpringBoard 注入实例中按宿主兜底。
    return !app.length&&[proc caseInsensitiveCompare:@"SpringBoard"]==NSOrderedSame;
}

@interface NSObject (SneakyCapturePrivate)
- (NSString *)applicationID;
@end

%hook FigCaptureClientSessionMonitor
- (void)_updateClientStateCondition:(id)condition newValue:(id)value {
    if (SCIsSpringBoardCaptureClient(self)) return;
    %orig;
}
%end

%hook FigCaptureClientSessionMonitorClient
- (BOOL)hasBackgroundCameraAccess {
    if (SCIsSpringBoardCaptureClient(self)) return YES;
    return %orig;
}
%end

// iOS 17 使用的新应用状态监视客户端类。
%hook FigCaptureClientApplicationStateMonitorClient
- (BOOL)hasBackgroundCameraAccess {
    if (SCIsSpringBoardCaptureClient(self)) return YES;
    return %orig;
}
%end

// RecordAnywhere 1.1.0 的锁屏状态策略：仅在开关启用时让 ReplayKit 认为设备未锁定。
%hook RPSystemRecordSession
- (void)handleDeviceLockedWarning { if(!SCKeepLockRecording()) %orig; }
%end

%hook RPRecordingManager
- (void)handleDeviceLockedWarning { if(!SCKeepLockRecording()) %orig; }
- (void)setUpDeviceLockNotifications { if(!SCKeepLockRecording()) %orig; }
- (BOOL)checkDeviceLockedRequirement { if(SCKeepLockRecording())return NO;return %orig; }
- (void)setDeviceLocked:(BOOL)locked { %orig(SCKeepLockRecording()?NO:locked); }
- (BOOL)deviceLocked { if(SCKeepLockRecording())return NO;return %orig; }
%end

%ctor { %init; }
