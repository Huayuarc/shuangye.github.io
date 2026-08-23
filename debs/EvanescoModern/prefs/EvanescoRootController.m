#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../EvanescoPrefs.h"

@interface EvanescoRootController : PSListController @end
@implementation EvanescoRootController
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *a=[NSMutableArray array];
        PSSpecifier *g=[PSSpecifier preferenceSpecifierNamed:@"Evanesco! Modern" target:self set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [g setProperty:@"闲置后淡出主屏图标；触摸、按键或解锁后立即恢复。" forKey:@"footerText"]; [a addObject:g];
        NSArray *rows=@[
          @[@"启用",@"enabled",@YES,@(PSSwitchCell)],
          @[@"隐藏 Dock",@"hideDock",@NO,@(PSSwitchCell)],
          @[@"隐藏状态栏",@"hideStatusBar",@NO,@(PSSwitchCell)]
        ];
        for (NSArray *r in rows) { PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:r[0] target:self set:@selector(setValue:specifier:) get:@selector(value:) detail:Nil cell:[r[3] integerValue] edit:Nil]; [s setProperty:r[1] forKey:@"key"]; [s setProperty:r[2] forKey:@"default"]; [a addObject:s]; }
        PSSpecifier *delay=[PSSpecifier preferenceSpecifierNamed:@"闲置时间（秒）" target:self set:@selector(setValue:specifier:) get:@selector(value:) detail:Nil cell:PSSliderCell edit:Nil];
        [delay setProperty:@"timeDelay" forKey:@"key"]; [delay setProperty:@10 forKey:@"default"]; [delay setProperty:@1 forKey:@"min"]; [delay setProperty:@120 forKey:@"max"]; [delay setProperty:@YES forKey:@"showValue"]; [a addObject:delay];
        PSSpecifier *alpha=[PSSpecifier preferenceSpecifierNamed:@"淡出后透明度" target:self set:@selector(setValue:specifier:) get:@selector(value:) detail:Nil cell:PSSliderCell edit:Nil];
        [alpha setProperty:@"alpha" forKey:@"key"]; [alpha setProperty:@0 forKey:@"default"]; [alpha setProperty:@0 forKey:@"min"]; [alpha setProperty:@1 forKey:@"max"]; [alpha setProperty:@YES forKey:@"showValue"]; [a addObject:alpha];
        _specifiers=[a copy];
    } return _specifiers;
}
- (id)value:(PSSpecifier *)s { return EVValue([s propertyForKey:@"key"],[s propertyForKey:@"default"]); }
- (void)setValue:(id)v specifier:(PSSpecifier *)s { EVSetValue([s propertyForKey:@"key"],v); }
@end
