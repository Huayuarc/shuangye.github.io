#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import <notify.h>
static void SCVideoChanged(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef u){SneakyCamCCVideo *m=(__bridge id)o;dispatch_async(dispatch_get_main_queue(),^{[m refreshState];});}
@implementation SneakyCamCCVideo
- (instancetype)init{if((self=[super init]))CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge const void*)self,SCVideoChanged,CFSTR("com.spark.SneakyCam.recordingstatechanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);return self;}
- (UIImage *)iconGlyph{return [UIImage systemImageNamed:@"video"];}- (UIImage *)selectedIconGlyph{return [UIImage systemImageNamed:@"video.fill"];}- (UIColor *)selectedColor{return [UIColor systemRedColor];}
- (BOOL)isSelected{return [SCReadPreferences()[@"Recording"] boolValue];}
- (void)setSelected:(BOOL)selected{notify_post("com.spark.SneakyCam.startstopvideo");[self refreshState];}
- (void)dealloc{CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge const void*)self,NULL,NULL);}
@end
