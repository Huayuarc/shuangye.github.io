#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface AKRRootListController : PSListController @end
@implementation AKRRootListController
- (NSArray *)specifiers {
 if(!_specifiers){
  NSMutableArray *s=[NSMutableArray array]; PSSpecifier *p;
  [s addObject:[PSSpecifier groupSpecifierWithName:@"Akara 中文重构版"]];
  p=[PSSpecifier preferenceSpecifierNamed:@"启用 Akara" target:self set:@selector(set:for:) get:@selector(get:) detail:nil cell:PSSwitchCell edit:nil]; [p setProperty:@YES forKey:@"default"]; [p setProperty:@"enabled" forKey:@"key"]; [s addObject:p];
  [s addObject:[PSSpecifier groupSpecifierWithName:@"外观"]];
  p=[PSSpecifier preferenceSpecifierNamed:@"使用深色模糊" target:self set:@selector(set:for:) get:@selector(get:) detail:nil cell:PSSwitchCell edit:nil]; [p setProperty:@YES forKey:@"default"]; [p setProperty:@"darkBlur" forKey:@"key"]; [s addObject:p];
  p=[PSSpecifier preferenceSpecifierNamed:@"面板宽度" target:self set:@selector(set:for:) get:@selector(get:) detail:nil cell:PSSliderCell edit:nil]; [p setProperty:@320 forKey:@"min"]; [p setProperty:@400 forKey:@"max"]; [p setProperty:@360 forKey:@"default"]; [p setProperty:@"panelWidth" forKey:@"key"]; [s addObject:p];
  p=[PSSpecifier preferenceSpecifierNamed:@"模块圆角" target:self set:@selector(set:for:) get:@selector(get:) detail:nil cell:PSSliderCell edit:nil]; [p setProperty:@8 forKey:@"min"]; [p setProperty:@30 forKey:@"max"]; [p setProperty:@18 forKey:@"default"]; [p setProperty:@"cornerRadius" forKey:@"key"]; [s addObject:p];
  PSSpecifier *g=[PSSpecifier groupSpecifierWithName:@"手势说明"]; [g setProperty:@"从屏幕底部左侧或右侧向上轻扫打开；中央 Home 手势区域完全保留给系统。面板内向下轻扫即可关闭。重构版不会创建底部横线或系统 Affordance。" forKey:@"footerText"]; [s addObject:g];
  p=[PSSpecifier preferenceSpecifierNamed:@"应用设置并注销" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; p->action=@selector(apply); [s addObject:p];
  _specifiers=s;
 } return _specifiers;
}
- (id)get:(PSSpecifier*)p { NSDictionary*d=[[NSUserDefaults standardUserDefaults]persistentDomainForName:@"com.huayuarc.akaracn"]?:@{}; return d[[p propertyForKey:@"key"]]?:[p propertyForKey:@"default"]; }
- (void)set:(id)v for:(PSSpecifier*)p { NSUserDefaults*u=[NSUserDefaults standardUserDefaults]; NSMutableDictionary*d=[[u persistentDomainForName:@"com.huayuarc.akaracn"] mutableCopy]?:[NSMutableDictionary dictionary]; d[[p propertyForKey:@"key"]]=v; [u setPersistentDomain:d forName:@"com.huayuarc.akaracn"]; }
- (void)apply { system("killall -9 SpringBoard"); }
@end
