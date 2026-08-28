#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

static atomic_bool gForce120=false;
static atomic_bool gCaptured=false;
static int gRefreshToken=0;

static BOOL CPUthermalCanRequest120(void){return atomic_load(&gForce120)&&!atomic_load(&gCaptured);}
static void CPUthermalReload(void){BOOL force=NO;CPUthermalReadRefreshRateState(&force);atomic_store(&gForce120,force);}

%group CPUthermalHello120Hooks
%hook UIScreen
- (NSInteger)maximumFramesPerSecond {
    return CPUthermalCanRequest120() ? 120 : %orig;
}
%end

%hook CADisplayLink
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector {
    CADisplayLink *link=%orig;
    if(CPUthermalCanRequest120()&&[link respondsToSelector:@selector(setPreferredFrameRateRange:)])link.preferredFrameRateRange=CAFrameRateRangeMake(10,120,120);
    return link;
}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if(CPUthermalCanRequest120()){
        range.maximum=120;
        range.preferred=120;
        if(range.minimum<=0||range.minimum>120)range.minimum=10;
    }
    %orig(range);
}
%end
%end

%ctor {@autoreleasepool {
    NSString *bundleID=NSBundle.mainBundle.bundleIdentifier;
    BOOL target=[bundleID isEqualToString:S("com.apple.springboard")]||[bundleID isEqualToString:S("com.apple.Preferences")];
    if(!target)return;
    CPUthermalReload();
    %init(CPUthermalHello120Hooks);
    // 延迟到目标进程完成 UIKit 初始化后再读取捕获状态。
    dispatch_async(dispatch_get_main_queue(),^{atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);[NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification*n){atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);}];});
    notify_register_dispatch(kCPUthermalRefreshRateNotifC,&gRefreshToken,dispatch_get_main_queue(),^(int token){(void)token;CPUthermalReload();});
}}
