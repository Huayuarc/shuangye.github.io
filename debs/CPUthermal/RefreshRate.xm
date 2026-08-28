#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

static atomic_bool gForce120=false;
static atomic_bool gCaptured=false;
static int gRefreshToken=0;

static BOOL CPUthermalRefreshEnabled(void){return atomic_load(&gForce120)&&!atomic_load(&gCaptured);}
static CAFrameRateRange CPUthermalTargetRange(void){return CAFrameRateRangeMake(10,120,120);}
static void CPUthermalReload(void){BOOL force=NO;CPUthermalReadRefreshRateState(&force);atomic_store(&gForce120,force);}

%group CPUthermalAlways120Hooks
%hook UIScreen
- (NSInteger)maximumFramesPerSecond { return CPUthermalRefreshEnabled()?120:%orig; }
%end

%hook CADisplayLink
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector {
    CADisplayLink *link=%orig;
    if(CPUthermalRefreshEnabled()){
        if([link respondsToSelector:@selector(setPreferredFrameRateRange:)])link.preferredFrameRateRange=CPUthermalTargetRange();
        else if([link respondsToSelector:@selector(setPreferredFramesPerSecond:)])link.preferredFramesPerSecond=120;
    }
    return link;
}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if(CPUthermalRefreshEnabled())%orig(CPUthermalTargetRange());else %orig(range);
}
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if(CPUthermalRefreshEnabled())%orig(120);else %orig(fps);
}
%end
%end

%ctor {@autoreleasepool {
    NSString *bundleID=NSBundle.mainBundle.bundleIdentifier;
    NSString *bundlePath=NSBundle.mainBundle.bundlePath?:S("");
    if(!bundleID.length)return;
    // 不进入扩展/小组件；排除列表中的第三方 App 完全不安装 Hook。
    if([[bundlePath pathExtension]caseInsensitiveCompare:S("appex")]==NSOrderedSame)return;
    if(![bundleID hasPrefix:S("com.apple.")]&&CPUthermalRefreshAppExcluded(bundleID))return;
    CPUthermalReload();
    %init(CPUthermalAlways120Hooks);
    atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);}];
    notify_register_dispatch(kCPUthermalRefreshRateNotifC,&gRefreshToken,dispatch_get_main_queue(),^(int token){(void)token;CPUthermalReload();});
}}
