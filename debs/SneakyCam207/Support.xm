#import <Foundation/Foundation.h>

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

%ctor { if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) %init; }
