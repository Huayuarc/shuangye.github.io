#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>
static atomic_bool gEnabled=false,gCaptured=false;static int gToken=0;
static BOOL Active(void){return atomic_load(&gEnabled)&&!atomic_load(&gCaptured);}
static void Reload(void){BOOL force=NO;CPUthermalReadRefreshRateState(&force);atomic_store(&gEnabled,force);}
%group App120Hooks
%hook UIScreen
- (NSInteger)maximumFramesPerSecond{return Active()?120:%orig;}
%end
%hook CADisplayLink
+ (CADisplayLink*)displayLinkWithTarget:(id)t selector:(SEL)s{CADisplayLink*l=%orig;if(Active())l.preferredFrameRateRange=CAFrameRateRangeMake(10,120,120);return l;}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)r{if(Active()){r.maximum=120;r.preferred=120;if(r.minimum<=0||r.minimum>120)r.minimum=10;}%orig(r);}
- (void)setPreferredFramesPerSecond:(NSInteger)fps{if(Active())%orig(120);else %orig(fps);}
%end
%end
%ctor{@autoreleasepool{NSString*bid=NSBundle.mainBundle.bundleIdentifier,*path=NSBundle.mainBundle.bundlePath?:S("");BOOL third=bid.length&&![bid hasPrefix:S("com.apple.")],app=[[path pathExtension]caseInsensitiveCompare:S("app")]==NSOrderedSame;if(!third||!app||!CPUthermalRefreshAppSelected(bid))return;Reload();%init(App120Hooks);atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);[NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification*n){atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);}];notify_register_dispatch(kCPUthermalRefreshRateNotifC,&gToken,dispatch_get_main_queue(),^(int t){(void)t;Reload();});}}
