#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

#ifndef __IPHONE_15_0
typedef struct { float minimum; float maximum; float preferred; } CAFrameRateRange;
#endif

static atomic_bool gForce120=false;
static atomic_bool gCaptured=false;
static NSHashTable<CADisplayLink*> *gLinks;
static CADisplayLink *gPersistentLink;
static CALayer *gDriverLayer;

@interface CADisplay:NSObject
+ (id)mainDisplay;
- (NSArray*)availableModes;
@end
@interface CADisplayPreferences:NSObject@end
@interface CAMutableDisplayPreferences:CADisplayPreferences@end
@interface CADynamicFrameRateSource:NSObject@end
@interface CAFrameRateRangeGroup:NSObject@end

static BOOL Supports120(void){static dispatch_once_t once;static BOOL ok=NO;dispatch_once(&once,^{Class c=NSClassFromString(S("CADisplay"));id d=[c respondsToSelector:@selector(mainDisplay)]?((id(*)(id,SEL))objc_msgSend)(c,@selector(mainDisplay)):nil;NSArray*m=[d respondsToSelector:@selector(availableModes)]?((id(*)(id,SEL))objc_msgSend)(d,@selector(availableModes)):nil;for(id x in m){id v=nil;@try{v=[x valueForKey:S("refreshRate")];}@catch(__unused NSException*e){}if([v doubleValue]>=119){ok=YES;break;}}});return ok;}
static BOOL ShouldHigh(void){return atomic_load(&gForce120)&&!atomic_load(&gCaptured)&&Supports120();}
static CAFrameRateRange Range(void){return CAFrameRateRangeMake(10,120,120);}
static void ApplyLink(CADisplayLink*l){if(!l)return;if([l respondsToSelector:@selector(setPreferredFrameRateRange:)])l.preferredFrameRateRange=ShouldHigh()?Range():CAFrameRateRangeMake(10,60,60);else l.preferredFramesPerSecond=ShouldHigh()?120:60;}
static void SetFloat(id o,const char*n,float v){SEL s=NSSelectorFromString(S(n));if(o&&[o respondsToSelector:s])((void(*)(id,SEL,float))objc_msgSend)(o,s,v);}
static void ApplyWindowServer(void){if(atomic_load(&gCaptured))return;Class c=NSClassFromString(S("CAWindowServer"));SEL ss=NSSelectorFromString(S("server"));id server=[c respondsToSelector:ss]?((id(*)(id,SEL))objc_msgSend)(c,ss):nil;SEL ds=NSSelectorFromString(S("displays"));NSArray*d=[server respondsToSelector:ds]?((id(*)(id,SEL))objc_msgSend)(server,ds):nil;for(id x in d){if(ShouldHigh()){SetFloat(x,"setMinimumRefreshRate:",120);SetFloat(x,"setMaximumRefreshRate:",120);SetFloat(x,"setIdealRefreshRate:",120);}}}
static void ApplyAll(void){dispatch_async(dispatch_get_main_queue(),^{if(gPersistentLink)gPersistentLink.paused=atomic_load(&gCaptured);if(!atomic_load(&gCaptured)){for(CADisplayLink*l in gLinks)ApplyLink(l);if(gPersistentLink){if([gPersistentLink respondsToSelector:@selector(setPreferredFrameRateRange:)])gPersistentLink.preferredFrameRateRange=ShouldHigh()?Range():CAFrameRateRangeMake(10,60,60);else gPersistentLink.preferredFramesPerSecond=ShouldHigh()?120:60;}}if(ShouldHigh()){CABasicAnimation*a=[CABasicAnimation animationWithKeyPath:S("opacity")];a.fromValue=@0.01;a.toValue=@0.011;a.duration=1;a.repeatCount=INFINITY;a.removedOnCompletion=NO;[gDriverLayer addAnimation:a forKey:S("CPUthermalProMotion120")];ApplyWindowServer();}else[gDriverLayer removeAnimationForKey:S("CPUthermalProMotion120")];});}
static void Reload(void){BOOL f=NO;CPUthermalReadRefreshRateState(&f);atomic_store(&gForce120,f);ApplyAll();}
static void Changed(CFNotificationCenterRef c,void*o,CFStringRef n,const void*x,CFDictionaryRef u){Reload();}
static void CapturedChanged(NSNotification*n){atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);ApplyAll();}

%group CPUthermalRefreshHooks
%hook UIScreen
- (NSInteger)maximumFramesPerSecond{return ShouldHigh()?120:%orig;}
%end
%hook CADisplayLink
+ (CADisplayLink*)displayLinkWithTarget:(id)t selector:(SEL)s{CADisplayLink*l=%orig;[gLinks addObject:l];ApplyLink(l);return l;}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)r{if(ShouldHigh())%orig(Range());else %orig(r);}
- (void)setPreferredFramesPerSecond:(NSInteger)f{if(ShouldHigh())%orig(120);else %orig(f);}
- (void)setFrameInterval:(NSInteger)i{if(ShouldHigh())%orig(1);else %orig(i);}
%end
%hook CAMutableDisplayPreferences
- (void)setPreferredRefreshRate:(double)r{if(ShouldHigh())%orig(120.0);else %orig(r);}
%end
%hook CADisplayPreferences
- (void)setPreferredRefreshRate:(double)r{if(ShouldHigh())%orig(120.0);else %orig(r);}
%end
%hook CADisplay
- (void)setPreferences:(id)p{if(ShouldHigh()&&p)@try{[p setValue:@120.0 forKey:S("preferredRefreshRate")];}@catch(__unused NSException*e){}%orig(p);}
%end
%hook CAContext
- (void)setPreferredFrameRateRange:(CAFrameRateRange)r{if(ShouldHigh()){r.maximum=120;r.preferred=120;}%orig(r);}
- (void)setPreferredFrameRate:(float)r{if(ShouldHigh()&&r>=60)%orig(120);else %orig(r);}
%end
%hook CADynamicFrameRateSource
- (void)setPreferredFrameRateRange:(CAFrameRateRange)r{if(ShouldHigh())r=CAFrameRateRangeMake(120,120,120);%orig(r);}
- (CAFrameRateRange)preferredFrameRateRange{CAFrameRateRange r=%orig;if(ShouldHigh())r=CAFrameRateRangeMake(120,120,120);return r;}
%end
%hook CAFrameRateRangeGroup
- (CAFrameRateRange)arbitratedRange{CAFrameRateRange r=%orig;if(ShouldHigh())r=CAFrameRateRangeMake(120,120,120);return r;}
%end
%end

%ctor{@autoreleasepool{
    NSString*bid=NSBundle.mainBundle.bundleIdentifier;BOOL target=[bid isEqualToString:S("com.apple.springboard")];if(!target)return;
    gLinks=[NSHashTable weakObjectsHashTable];%init(CPUthermalRefreshHooks);CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,Changed,(__bridge CFStringRef)S(kCPUthermalRefreshRateNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_async(dispatch_get_main_queue(),^{atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);[NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){CapturedChanged(n);}];Reload();});
    if([bid isEqualToString:S("com.apple.springboard")])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{gDriverLayer=[CALayer layer];gDriverLayer.opacity=0.01;gPersistentLink=[CADisplayLink displayLinkWithTarget:gDriverLayer selector:@selector(setNeedsDisplay)];[gPersistentLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];ApplyAll();});
}}
