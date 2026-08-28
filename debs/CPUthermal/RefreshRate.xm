#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

static atomic_bool gForce120=false;
static atomic_bool gScreenCaptured=false;
static BOOL gIsSpringBoard=false;
static CADisplayLink *gPersistentLink;
static CALayer *gDriverLayer;

@interface CADisplay : NSObject
+ (id)mainDisplay;
- (NSArray *)availableModes;
@end
static BOOL CPUthermalSupports120Hz(void){static dispatch_once_t once;static BOOL supported=NO;dispatch_once(&once,^{Class c=NSClassFromString(S("CADisplay"));id d=[c respondsToSelector:@selector(mainDisplay)]?((id(*)(id,SEL))objc_msgSend)(c,@selector(mainDisplay)):nil;NSArray*m=[d respondsToSelector:@selector(availableModes)]?((id(*)(id,SEL))objc_msgSend)(d,@selector(availableModes)):nil;for(id x in m){id v=nil;@try{v=[x valueForKey:S("refreshRate")];}@catch(__unused NSException*e){}if([v doubleValue]>=119){supported=YES;break;}}});return supported;}
static BOOL CPUthermalHighAllowed(void){return atomic_load(&gForce120)&&!atomic_load(&gScreenCaptured)&&CPUthermalSupports120Hz();}
static void CPUthermalSetFloat(id obj,const char*name,float value){SEL s=NSSelectorFromString(S(name));if(obj&&[obj respondsToSelector:s])((void(*)(id,SEL,float))objc_msgSend)(obj,s,value);}
static void CPUthermalApplyWindowServer(BOOL high){if(!gIsSpringBoard)return;Class c=NSClassFromString(S("CAWindowServer"));SEL ss=NSSelectorFromString(S("server"));id server=[c respondsToSelector:ss]?((id(*)(id,SEL))objc_msgSend)(c,ss):nil;SEL ds=NSSelectorFromString(S("displays"));NSArray*displays=[server respondsToSelector:ds]?((id(*)(id,SEL))objc_msgSend)(server,ds):nil;for(id d in displays){SEL allow=NSSelectorFromString(S("setAllowsVirtualModes:"));if([d respondsToSelector:allow])((void(*)(id,SEL,BOOL))objc_msgSend)(d,allow,YES);BOOL enabled=atomic_load(&gForce120);float minimum=high?120:(enabled?60:10);float maximum=high?120:(enabled?60:120);float ideal=high?120:60;CPUthermalSetFloat(d,"setMinimumRefreshRate:",minimum);CPUthermalSetFloat(d,"setMaximumRefreshRate:",maximum);CPUthermalSetFloat(d,"setIdealRefreshRate:",ideal);}}
static void CPUthermalApply(void){dispatch_async(dispatch_get_main_queue(),^{BOOL high=CPUthermalHighAllowed();if(gPersistentLink){gPersistentLink.preferredFrameRateRange=high?CAFrameRateRangeMake(120,120,120):CAFrameRateRangeMake(10,60,60);SEL reason=NSSelectorFromString(S("setHighFrameRateReason:"));if(high&&[gPersistentLink respondsToSelector:reason])((void(*)(id,SEL,BOOL))objc_msgSend)(gPersistentLink,reason,YES);}if(high){CABasicAnimation*a=[CABasicAnimation animationWithKeyPath:S("opacity")];a.fromValue=@0.01;a.toValue=@0.011;a.duration=1;a.repeatCount=INFINITY;a.removedOnCompletion=NO;[gDriverLayer addAnimation:a forKey:S("CPUthermalProMotion120")];}else[gDriverLayer removeAnimationForKey:S("CPUthermalProMotion120")];CPUthermalApplyWindowServer(high);});}
static void CPUthermalReload(void){BOOL force=NO;CPUthermalReadRefreshRateState(&force);atomic_store(&gForce120,force);CPUthermalApply();}
static void CPUthermalChanged(CFNotificationCenterRef c,void*o,CFStringRef n,const void*x,CFDictionaryRef u){CPUthermalReload();}
static void CPUthermalCaptureChanged(NSNotification*n){atomic_store(&gScreenCaptured,UIScreen.mainScreen.isCaptured);CPUthermalApply();}

%group CPUthermalAppRefreshHooks
%hook UIScreen
- (NSInteger)maximumFramesPerSecond{return CPUthermalHighAllowed()?120:%orig;}
%end
%hook CADisplayLink
+ (CADisplayLink*)displayLinkWithTarget:(id)target selector:(SEL)selector{CADisplayLink*link=%orig;if(CPUthermalHighAllowed())link.preferredFrameRateRange=CAFrameRateRangeMake(10,120,120);return link;}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range{if(CPUthermalHighAllowed()){range.maximum=120;range.preferred=120;}%orig(range);}
- (void)setPreferredFramesPerSecond:(NSInteger)fps{if(CPUthermalHighAllowed())%orig(120);else %orig;}
- (void)setFrameInterval:(NSInteger)interval{if(CPUthermalHighAllowed())%orig(1);else %orig;}
%end
%end

%ctor{@autoreleasepool{
    NSString*bid=NSBundle.mainBundle.bundleIdentifier;gIsSpringBoard=[bid isEqualToString:S("com.apple.springboard")];
    BOOL thirdParty=bid.length&&![bid hasPrefix:S("com.apple.")];
    if(thirdParty&&CPUthermalRefreshAppExcluded(bid))return;
    // 扩展与特殊宿主不安装 App 层 Hook，减少 Widget/ReplayKit/相机链冲突。
    NSString*path=NSBundle.mainBundle.bundlePath?:S("");BOOL extension=[[path pathExtension]caseInsensitiveCompare:S("appex")]==NSOrderedSame;
    if(!extension)%init(CPUthermalAppRefreshHooks);
    atomic_store(&gScreenCaptured,UIScreen.mainScreen.isCaptured);
    CPUthermalReload();CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,CPUthermalChanged,(__bridge CFStringRef)S(kCPUthermalRefreshRateNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){CPUthermalCaptureChanged(n);}];
    if(gIsSpringBoard)dispatch_async(dispatch_get_main_queue(),^{gDriverLayer=[CALayer layer];gDriverLayer.opacity=0.01;gPersistentLink=[CADisplayLink displayLinkWithTarget:gDriverLayer selector:@selector(setNeedsDisplay)];[gPersistentLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];CPUthermalApply();});
}}
