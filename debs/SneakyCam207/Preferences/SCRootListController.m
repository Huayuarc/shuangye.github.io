#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../SCPaths.h"
#import <UIKit/UIKit.h>

@interface SCRootListController : PSListController @end
static void SCPreferencesStateChanged(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef u){ SCRootListController *vc=(__bridge id)o; dispatch_async(dispatch_get_main_queue(),^{ [vc reloadSpecifierID:@"ButtonHookStatus"];[vc reloadSpecifierID:@"LastActionDate"];[vc reloadSpecifierID:@"LastActionStatus"]; }); }
@implementation SCRootListController
- (instancetype)init { if((self=[super init])){ CFNotificationCenterRef dc=CFNotificationCenterGetDarwinNotifyCenter();CFNotificationCenterAddObserver(dc,(__bridge const void*)self,SCPreferencesStateChanged,CFSTR("com.spark.SneakyCam.actionstatechanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);CFNotificationCenterAddObserver(dc,(__bridge const void*)self,SCPreferencesStateChanged,CFSTR("com.spark.SneakyCam.recordingstatechanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);} return self; }
- (NSArray *)specifiers { if(!_specifiers){_specifiers=[self loadSpecifiersFromPlistName:@"Root" target:self];for(PSSpecifier *s in _specifiers){NSString *k=s.properties[@"key"];if(k.length)[s setProperty:k forKey:@"id"];}} return _specifiers; }
- (id)readPreferenceValue:(PSSpecifier *)s { id v=SCReadPreferences()[s.properties[@"key"]]; return v ?: s.properties[@"default"]; }
- (void)setPreferenceValue:(id)v specifier:(PSSpecifier *)s { NSString *key=s.properties[@"key"]; SCWritePreference(key,v); NSString *n=s.properties[@"PostNotification"] ?: @"com.spark.SneakyCam"; CFNotificationCenterRef dc=CFNotificationCenterGetDarwinNotifyCenter(); CFNotificationCenterPostNotification(dc,(__bridge CFStringRef)n,NULL,NULL,YES); if([key isEqualToString:@"Enabled"])CFNotificationCenterPostNotification(dc,CFSTR("com.spark.SneakyCam.enabledchanged"),NULL,NULL,YES); }
- (void)openDownloads {
    // 末尾 / 强制 Filza 将路径识别为要进入的目录，而不是在父目录中高亮该目录。
    NSURL *primary=[NSURL URLWithString:@"filza://view/var/mobile/Downloads/"];
    NSURL *fallback=[NSURL URLWithString:@"filza://view//var/mobile/Downloads/"];
    UIApplication *app=[UIApplication sharedApplication];
    if([app canOpenURL:primary]) {
        [app openURL:primary options:@{} completionHandler:^(BOOL ok){
            if(!ok) [app openURL:fallback options:@{} completionHandler:nil];
            SCWritePreference(@"LastActionStatus", ok?@"已进入 /var/mobile/Downloads":@"正在尝试打开 Downloads");
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.spark.SneakyCam.actionstatechanged"),NULL,NULL,YES);
        }];
    } else {
        SCWritePreference(@"LastActionStatus", @"未检测到 Filza，请安装后重试");
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.spark.SneakyCam.actionstatechanged"),NULL,NULL,YES);
        [self reloadSpecifierID:@"LastActionStatus"];
    }
}
- (void)takePhoto { CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.spark.SneakyCam.takephoto"),NULL,NULL,YES); }
- (void)toggleVideo { CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.spark.SneakyCam.startstopvideo"),NULL,NULL,YES); }
- (void)respring { CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.spark.SneakyCam.respring"),NULL,NULL,YES); }
- (void)dealloc { CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge const void*)self,NULL,NULL); }
@end
