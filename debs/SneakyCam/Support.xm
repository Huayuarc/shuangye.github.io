#import <Foundation/Foundation.h>
#import "SCPaths.h"

static BOOL SCKeepLockRecording(void){ id v=SCReadPreferences()[@"LockScreenKeepRecording"]; return v?[v boolValue]:YES; }

@interface NSObject (SneakyCapturePrivate)
- (NSString *)applicationID;
@end

%hook FigCaptureClientSessionMonitor
- (void)_updateClientStateCondition:(id)condition newValue:(id)value {
    NSString *app = [((id)self) respondsToSelector:@selector(applicationID)] ? [((id)self) applicationID] : nil;
    if ([app isEqualToString:@"com.apple.springboard"]) return;
    %orig;
}
%end

%hook FigCaptureClientSessionMonitorClient
- (BOOL)hasBackgroundCameraAccess {
    NSString *app = [((id)self) respondsToSelector:@selector(applicationID)] ? [((id)self) applicationID] : nil;
    if ([app isEqualToString:@"com.apple.springboard"]) return YES;
    return %orig;
}
%end

// iOS 17 使用的新应用状态监视客户端类。
%hook FigCaptureClientApplicationStateMonitorClient
- (BOOL)hasBackgroundCameraAccess {
    NSString *app = [((id)self) respondsToSelector:@selector(applicationID)] ? [((id)self) applicationID] : nil;
    if ([app isEqualToString:@"com.apple.springboard"]) return YES;
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
