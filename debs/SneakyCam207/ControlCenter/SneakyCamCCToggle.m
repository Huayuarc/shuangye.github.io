#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import <notify.h>
static void SCToggleChanged(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef u){SneakyCamCCToggle *m=(__bridge id)o;dispatch_async(dispatch_get_main_queue(),^{[m refreshState];});}
@implementation SneakyCamCCToggle
- (instancetype)init{if((self=[super init]))CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge const void*)self,SCToggleChanged,CFSTR("com.spark.SneakyCam.enabledchanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);return self;}
- (UIImage *)iconGlyph{UIImageSymbolConfiguration *c=[UIImageSymbolConfiguration configurationWithPointSize:44 weight:UIImageSymbolWeightSemibold];return [UIImage systemImageNamed:@"power.circle" withConfiguration:c];}- (UIImage *)selectedIconGlyph{UIImageSymbolConfiguration *c=[UIImageSymbolConfiguration configurationWithPointSize:44 weight:UIImageSymbolWeightSemibold];return [UIImage systemImageNamed:@"power.circle.fill" withConfiguration:c];}- (UIColor *)selectedColor{return [UIColor systemOrangeColor];}
- (BOOL)isSelected{id v=SCReadPreferences()[@"Enabled"];return v?[v boolValue]:NO;}
- (void)setSelected:(BOOL)selected{SCWritePreference(@"Enabled",@(selected));notify_post("com.spark.SneakyCam.enabledchanged");notify_post("com.spark.SneakyCam");[self refreshState];}
- (void)dealloc{CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge const void*)self,NULL,NULL);}
@end
