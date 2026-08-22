#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <objc/runtime.h>
#import <CPUthermalPaths.h>

// 注入所有 UIKit 应用，只负责报告当前前台 Bundle ID；实际功率切换仍由 thermalmonitord 执行。
static void CPUthermalPostForegroundBundleID(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return;
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs() ?: [NSMutableDictionary dictionary];
    if ([prefs[S("foregroundBundleID")] isEqualToString:bundleID]) return;
    prefs[S("foregroundBundleID")] = bundleID;
    CPUthermalWritePrefs(prefs);
    notify_post(kCPUthermalSettingsChangedNotifC);
}

static void CPUthermalPostCurrentApplication(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application.applicationState != UIApplicationStateActive) return;
    CPUthermalPostForegroundBundleID([[NSBundle mainBundle] bundleIdentifier]);
}

%hook UIApplication
- (void)didBecomeActive {
    %orig;
    CPUthermalPostCurrentApplication();
}
%end

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
                CPUthermalPostCurrentApplication();
            }];
            CPUthermalPostCurrentApplication();
        });
    }
}
