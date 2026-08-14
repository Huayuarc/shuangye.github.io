#import <Foundation/Foundation.h>

%hook FigCaptureClientSessionMonitor
- (void)_updateClientStateCondition:(id)condition newValue:(id)value {
    NSString *app = nil; if ([self respondsToSelector:@selector(applicationID)]) app = [self performSelector:@selector(applicationID)];
    if ([app isEqualToString:@"com.apple.springboard"]) return;
    %orig;
}
%end

%hook FigCaptureClientSessionMonitorClient
- (BOOL)hasBackgroundCameraAccess {
    NSString *app = nil; if ([self respondsToSelector:@selector(applicationID)]) app = [self performSelector:@selector(applicationID)];
    if ([app isEqualToString:@"com.apple.springboard"]) return YES;
    return %orig;
}
%end

%ctor { if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) %init; }
