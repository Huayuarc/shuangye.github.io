#import <UIKit/UIKit.h>
#import "SCCaptureManager.h"
#import "SCPaths.h"

static NSTimeInterval SCUpTime=0, SCDownTime=0;
static void SCTrigger(BOOL video) { dispatch_async(dispatch_get_main_queue(), ^{ if(video)[[SCCaptureManager shared] toggleVideo];else[[SCCaptureManager shared] takePhoto]; }); }
static void SCNotification(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) { NSString *s=(__bridge NSString *)n; SCTrigger([s hasSuffix:@"startstopvideo"]); }

%hook SBVolumeControl
- (void)increaseVolume { %orig; NSDictionary *p=SCReadPreferences(); if(![p[@"UseVolumeButtons"] ?: @YES boolValue])return; NSTimeInterval t=NSProcessInfo.processInfo.systemUptime;if(t-SCUpTime<0.45)SCTrigger(YES);SCUpTime=t; }
- (void)decreaseVolume { %orig; NSDictionary *p=SCReadPreferences(); if(![p[@"UseVolumeButtons"] ?: @YES boolValue])return; NSTimeInterval t=NSProcessInfo.processInfo.systemUptime;if(t-SCDownTime<0.45)SCTrigger(NO);SCDownTime=t; }
%end

%ctor { @autoreleasepool { SCMigratePreferencesIfNeeded(); CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SCNotification, CFSTR("com.spark.SneakyCam.takephoto"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately); CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SCNotification, CFSTR("com.spark.SneakyCam.startstopvideo"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately); } }
