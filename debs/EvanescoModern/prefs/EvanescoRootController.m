#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
extern char **environ;
#import "../EvanescoPrefs.h"

@interface EvanescoRootController : PSListController @end
@implementation EvanescoRootController
- (NSArray *)specifiers {
 if(!_specifiers){ NSMutableArray *a=[NSMutableArray array]; PSSpecifier *s;
  s=[PSSpecifier groupSpecifierWithName:@"Evanesco! Modern"]; [s setProperty:@"闲置指定时间后淡出桌面图标和组件。触摸、滑动、按键、解锁或打开应用时立即恢复，不影响桌面翻页和图标操作。" forKey:@"footerText"]; [a addObject:s];
  s=[PSSpecifier preferenceSpecifierNamed:@"启用插件" target:self set:@selector(setValue:specifier:) get:@selector(value:) detail:Nil cell:PSSwitchCell edit:Nil]; [s setProperty:@"enabled" forKey:@"key"]; [s setProperty:@YES forKey:@"default"]; [a addObject:s];

  s=[PSSpecifier groupSpecifierWithName:@"淡出行为"]; [s setProperty:@"淡出只修改图标和组件叶子视图，不再隐藏承载手势的桌面容器。" forKey:@"footerText"]; [a addObject:s];
  s=[PSSpecifier preferenceSpecifierNamed:@"同时淡出 Dock" target:self set:@selector(setValue:specifier:) get:@selector(value:) detail:Nil cell:PSSwitchCell edit:Nil]; [s setProperty:@"hideDock" forKey:@"key"]; [s setProperty:@NO forKey:@"default"]; [a addObject:s];
  s=[PSSpecifier preferenceSpecifierNamed:@"隐藏桌面状态栏" target:self set:@selector(setValue:specifier:) get:@selector(value:) detail:Nil cell:PSSwitchCell edit:Nil]; [s setProperty:@"hideStatusBar" forKey:@"key"]; [s setProperty:@NO forKey:@"default"]; [a addObject:s];

  s=[PSSpecifier groupSpecifierWithName:@"时间与透明度"]; [s setProperty:@"闲置时间范围 1–120 秒。透明度最低保留 2%，避免 UIKit 将桌面内容误判为不可交互区域。" forKey:@"footerText"]; [a addObject:s];
  s=[PSSpecifier preferenceSpecifierNamed:@"闲置时间（秒）" target:self set:@selector(setValue:specifier:) get:@selector(value:) detail:Nil cell:PSSliderCell edit:Nil]; [s setProperty:@"timeDelay" forKey:@"key"]; [s setProperty:@10 forKey:@"default"]; [s setProperty:@1 forKey:@"min"]; [s setProperty:@120 forKey:@"max"]; [s setProperty:@YES forKey:@"showValue"]; [a addObject:s];
  s=[PSSpecifier preferenceSpecifierNamed:@"淡出后透明度" target:self set:@selector(setValue:specifier:) get:@selector(value:) detail:Nil cell:PSSliderCell edit:Nil]; [s setProperty:@"alpha" forKey:@"key"]; [s setProperty:@0.05 forKey:@"default"]; [s setProperty:@0.02 forKey:@"min"]; [s setProperty:@1 forKey:@"max"]; [s setProperty:@YES forKey:@"showValue"]; [a addObject:s];

  s=[PSSpecifier groupSpecifierWithName:@"维护"]; [s setProperty:@"设置会实时通知 SpringBoard。若系统缓存了旧插件状态，可执行注销以重新加载全部组件。" forKey:@"footerText"]; [a addObject:s];
  s=[PSSpecifier preferenceSpecifierNamed:@"恢复默认设置" target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil]; s->action=@selector(resetSettings); [a addObject:s];
  s=[PSSpecifier preferenceSpecifierNamed:@"注销 SpringBoard" target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil]; s->action=@selector(respring); [s setProperty:@"red" forKey:@"color"]; [a addObject:s];
  s=[PSSpecifier groupSpecifierWithName:nil]; [s setProperty:@"Evanesco! Modern 2024.05.28\n基于 Randy-420/evanesco 行为重构，适配 iOS 15–17、rootless 与 RootHide。" forKey:@"footerText"]; [a addObject:s]; _specifiers=[a copy];
 } return _specifiers;
}
- (id)value:(PSSpecifier *)s{return EVValue([s propertyForKey:@"key"],[s propertyForKey:@"default"]);}
- (void)setValue:(id)v specifier:(PSSpecifier *)s{EVSetValue([s propertyForKey:@"key"],v);}
- (void)resetSettings{ for(NSString *k in @[@"enabled",@"hideDock",@"hideStatusBar",@"timeDelay",@"alpha"])EVSetValue(k,nil); [self reloadSpecifiers]; }
- (void)respring{ pid_t pid=0; char *argv[]={(char *)"killall",(char *)"-9",(char *)"SpringBoard",NULL}; posix_spawn(&pid,"/usr/bin/killall",NULL,NULL,argv,environ); }
@end
