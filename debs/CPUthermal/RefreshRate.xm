#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

static atomic_bool gForce120=false;
static atomic_bool gScreenCaptured=false;
static CADisplayLink *gPersistentLink;
static CALayer *gDriverLayer;
static id gCaptureObserver;

@interface CADisplay : NSObject
+ (id)mainDisplay;
- (NSArray *)availableModes;
@end

static BOOL CPUthermalSupports120Hz(void){
    static BOOL checked=NO,supported=NO;if(checked)return supported;checked=YES;
    @try{Class c=NSClassFromString(S("CADisplay"));id d=[c respondsToSelector:@selector(mainDisplay)]?((id(*)(id,SEL))objc_msgSend)(c,@selector(mainDisplay)):nil;NSArray*m=[d respondsToSelector:@selector(availableModes)]?((id(*)(id,SEL))objc_msgSend)(d,@selector(availableModes)):nil;for(id x in m){id v=[x valueForKey:S("refreshRate")];if([v doubleValue]>=119){supported=YES;break;}}}@catch(__unused NSException*e){}
    return supported;
}
static BOOL CPUthermalHighAllowed(void){return atomic_load(&gForce120)&&!atomic_load(&gScreenCaptured)&&CPUthermalSupports120Hz();}
static void CPUthermalApply(void){
    dispatch_async(dispatch_get_main_queue(),^{
        BOOL captured=atomic_load(&gScreenCaptured),high=CPUthermalHighAllowed();
        if(gPersistentLink){gPersistentLink.paused=captured;if(!captured){if([gPersistentLink respondsToSelector:@selector(setPreferredFrameRateRange:)])gPersistentLink.preferredFrameRateRange=high?CAFrameRateRangeMake(120,120,120):CAFrameRateRangeMake(10,60,60);else gPersistentLink.preferredFramesPerSecond=high?120:60;SEL reason=NSSelectorFromString(S("setHighFrameRateReason:"));if(high&&[gPersistentLink respondsToSelector:reason])((void(*)(id,SEL,BOOL))objc_msgSend)(gPersistentLink,reason,YES);}}
        if(captured||!high){[gDriverLayer removeAnimationForKey:S("CPUthermalProMotion120")];return;}
        CABasicAnimation*a=[CABasicAnimation animationWithKeyPath:S("opacity")];a.fromValue=@0.01;a.toValue=@0.011;a.duration=1;a.repeatCount=INFINITY;a.removedOnCompletion=NO;[gDriverLayer addAnimation:a forKey:S("CPUthermalProMotion120")];
    });
}
static void CPUthermalReload(void){BOOL force=NO;CPUthermalReadRefreshRateState(&force);atomic_store(&gForce120,force);CPUthermalApply();}
static void CPUthermalChanged(CFNotificationCenterRef c,void*o,CFStringRef n,const void*x,CFDictionaryRef u){CPUthermalReload();}
static void CPUthermalStartDriver(void){
    if(gPersistentLink)return;
    UIScreen*screen=UIScreen.mainScreen;atomic_store(&gScreenCaptured,screen.isCaptured);
    gDriverLayer=[CALayer layer];gDriverLayer.opacity=0.01;
    gPersistentLink=[CADisplayLink displayLinkWithTarget:gDriverLayer selector:@selector(setNeedsDisplay)];
    [gPersistentLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    gCaptureObserver=[NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification*n){atomic_store(&gScreenCaptured,UIScreen.mainScreen.isCaptured);CPUthermalApply();}];
    CPUthermalReload();
}

%ctor{@autoreleasepool{
    NSString*bid=NSBundle.mainBundle.bundleIdentifier;
    // Preferences 只负责让配置组件可见；刷新驱动仅在 SpringBoard 延迟启动。
    if(![bid isEqualToString:S("com.apple.springboard")])return;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,CPUthermalChanged,(__bridge CFStringRef)S(kCPUthermalRefreshRateNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    // 避开 SpringBoard/UIScreen 构造早期，降低不同 iOS 版本启动阶段 Safe Mode 风险。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{CPUthermalStartDriver();});
}}
