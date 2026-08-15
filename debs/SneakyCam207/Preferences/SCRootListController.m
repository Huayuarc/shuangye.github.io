#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../SCPaths.h"
#import <UIKit/UIKit.h>

@interface SCRootListController : PSListController @end
@implementation SCRootListController
- (NSArray *)specifiers { if(!_specifiers)_specifiers=[self loadSpecifiersFromPlistName:@"Root" target:self]; return _specifiers; }
- (id)readPreferenceValue:(PSSpecifier *)s { id v=SCReadPreferences()[s.properties[@"key"]]; return v ?: s.properties[@"default"]; }
- (void)setPreferenceValue:(id)v specifier:(PSSpecifier *)s { NSString *key=s.properties[@"key"]; SCWritePreference(key,v); NSString *n=s.properties[@"PostNotification"] ?: @"com.spark.SneakyCam"; CFNotificationCenterRef dc=CFNotificationCenterGetDarwinNotifyCenter(); CFNotificationCenterPostNotification(dc,(__bridge CFStringRef)n,NULL,NULL,YES); if([key isEqualToString:@"Enabled"])CFNotificationCenterPostNotification(dc,CFSTR("com.spark.SneakyCam.enabledchanged"),NULL,NULL,YES); }
- (void)takePhoto { CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.spark.SneakyCam.takephoto"),NULL,NULL,YES); }
- (void)toggleVideo { CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.spark.SneakyCam.startstopvideo"),NULL,NULL,YES); }
- (void)respring { CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.spark.SneakyCam.respring"),NULL,NULL,YES); }
@end
