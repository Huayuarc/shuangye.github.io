#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <objc/runtime.h>
#import <CPUthermalPaths.h>

// 沙盒应用只通过 Darwin notify state 报告前台 Bundle ID 哈希，
// 不直接写越狱根偏好文件；thermalmonitord 收到后自行匹配 lowPowerApps。
static void CPUthermalReportCurrentApplication(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application.applicationState != UIApplicationStateActive) return;
    CPUthermalPostForegroundBundleID([[NSBundle mainBundle] bundleIdentifier]);
}

%hook UIApplication
- (void)didBecomeActive {
    %orig;
    CPUthermalReportCurrentApplication();
}
- (void)didEnterBackground {
    %orig;
    CPUthermalPostForegroundBundleID(nil);
}
%end

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
                CPUthermalReportCurrentApplication();
            }];
            CPUthermalReportCurrentApplication();
        });
    }
}
