#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

static atomic_bool gForce120=false;
static CADisplayLink *gPersistentLink;
static CALayer *gDriverLayer;

@interface CADisplay : NSObject
+ (id)mainDisplay;
- (NSArray *)availableModes;
@end

static BOOL CPUthermalSupports120Hz(void) {
    static dispatch_once_t once; static BOOL supported=NO;
    dispatch_once(&once,^{
        Class cls=NSClassFromString(S("CADisplay"));
        id display=[cls respondsToSelector:@selector(mainDisplay)]?((id(*)(id,SEL))objc_msgSend)(cls,@selector(mainDisplay)):nil;
        NSArray *modes=[display respondsToSelector:@selector(availableModes)]?((id(*)(id,SEL))objc_msgSend)(display,@selector(availableModes)):nil;
        for(id mode in modes){id value=nil;@try{value=[mode valueForKey:S("refreshRate")];}@catch(__unused NSException *e){}if([value doubleValue]>=119.0){supported=YES;break;}}
    });
    return supported;
}
static BOOL CPUthermalShouldForce120(void){return atomic_load(&gForce120)&&CPUthermalSupports120Hz();}
static void CPUthermalApplyPersistentLink(void){
    if(!gPersistentLink)return;
    if([gPersistentLink respondsToSelector:@selector(setPreferredFrameRateRange:)])gPersistentLink.preferredFrameRateRange=CPUthermalShouldForce120()?CAFrameRateRangeMake(120,120,120):CAFrameRateRangeMake(10,60,60);
    else gPersistentLink.preferredFramesPerSecond=CPUthermalShouldForce120()?120:60;
    SEL reason=NSSelectorFromString(S("setHighFrameRateReason:"));if(CPUthermalShouldForce120()&&[gPersistentLink respondsToSelector:reason])((void(*)(id,SEL,BOOL))objc_msgSend)(gPersistentLink,reason,YES);
}
static void CPUthermalSetFloat(id obj,const char *name,float value){SEL sel=NSSelectorFromString(S(name));if(obj&&[obj respondsToSelector:sel])((void(*)(id,SEL,float))objc_msgSend)(obj,sel,value);}
static void CPUthermalApplyWindowServer(void){
    if(!CPUthermalShouldForce120())return;
    Class cls=NSClassFromString(S("CAWindowServer"));SEL serverSel=NSSelectorFromString(S("server"));id server=[cls respondsToSelector:serverSel]?((id(*)(id,SEL))objc_msgSend)(cls,serverSel):nil;
    SEL displaysSel=NSSelectorFromString(S("displays"));NSArray *displays=[server respondsToSelector:displaysSel]?((id(*)(id,SEL))objc_msgSend)(server,displaysSel):nil;
    for(id display in displays){SEL allow=NSSelectorFromString(S("setAllowsVirtualModes:"));if([display respondsToSelector:allow])((void(*)(id,SEL,BOOL))objc_msgSend)(display,allow,YES);CPUthermalSetFloat(display,"setMinimumRefreshRate:",120);CPUthermalSetFloat(display,"setMaximumRefreshRate:",120);CPUthermalSetFloat(display,"setIdealRefreshRate:",120);}
}
static void CPUthermalApply(void){
    dispatch_async(dispatch_get_main_queue(),^{
        CPUthermalApplyPersistentLink();
        if(CPUthermalShouldForce120()){
            CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:S("opacity")];a.fromValue=@0.01;a.toValue=@0.011;a.duration=1;a.repeatCount=INFINITY;a.removedOnCompletion=NO;[gDriverLayer addAnimation:a forKey:S("CPUthermalProMotion120")];CPUthermalApplyWindowServer();
        }else [gDriverLayer removeAnimationForKey:S("CPUthermalProMotion120")];
    });
}
static void CPUthermalReload(void){BOOL force=NO;CPUthermalReadRefreshRateState(&force);atomic_store(&gForce120,force);CPUthermalApply();}
static void CPUthermalChanged(CFNotificationCenterRef c,void *o,CFStringRef n,const void *x,CFDictionaryRef u){CPUthermalReload();}

%ctor {@autoreleasepool{
    NSString *bundle=NSBundle.mainBundle.bundleIdentifier;
    BOOL springboard=[bundle isEqualToString:S("com.apple.springboard")];
    BOOL notificationHost=[bundle isEqualToString:S("com.apple.UserNotificationsUIServer")]||[bundle isEqualToString:S("com.apple.springboard.SpringBoardOutofCallUI")];
    if(!springboard&&!notificationHost)return;
    CPUthermalReload();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,CPUthermalChanged,(__bridge CFStringRef)S(kCPUthermalRefreshRateNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    // iOS 17 小组件安全：通知宿主仅监听状态，不安装全局 CA Hook；SpringBoard 只创建插件私有刷新源。
    if(springboard)dispatch_async(dispatch_get_main_queue(),^{gDriverLayer=[CALayer layer];gDriverLayer.opacity=0.01;gPersistentLink=[CADisplayLink displayLinkWithTarget:gDriverLayer selector:@selector(setNeedsDisplay)];[gPersistentLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];CPUthermalApply();});
}}
