#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

#ifndef __IPHONE_15_0
typedef struct { float minimum; float maximum; float preferred; } CAFrameRateRange;
#endif

static atomic_bool gForce120 = false;
static NSHashTable<CADisplayLink *> *gDisplayLinks;
static CADisplayLink *gPersistentLink;
static CALayer *gDriverLayer;

@interface CADisplay : NSObject
+ (id)mainDisplay;
- (NSArray *)availableModes;
- (void)setPreferences:(id)value;
@end
@interface CADisplayPreferences : NSObject @end
@interface CAMutableDisplayPreferences : CADisplayPreferences @end
@interface CADynamicFrameRateSource : NSObject @end
@interface CAFrameRateRangeGroup : NSObject @end

static BOOL CPUthermalSupports120Hz(void) {
    static dispatch_once_t once; static BOOL supported = NO;
    dispatch_once(&once, ^{
        Class cls=NSClassFromString(S("CADisplay")); id display=[cls respondsToSelector:@selector(mainDisplay)]?((id(*)(id,SEL))objc_msgSend)(cls,@selector(mainDisplay)):nil;
        NSArray *modes=[display respondsToSelector:@selector(availableModes)]?((id(*)(id,SEL))objc_msgSend)(display,@selector(availableModes)):nil;
        for(id mode in modes){id value=nil;@try{value=[mode valueForKey:S("refreshRate")];}@catch(__unused NSException *e){} if([value doubleValue]>=119.0){supported=YES;break;}}
    });
    return supported;
}

static BOOL CPUthermalShouldForce120(void) {
    return atomic_load(&gForce120)&&CPUthermalSupports120Hz();
}
static CAFrameRateRange CPUthermalRange(BOOL high) { return CAFrameRateRangeMake(high?120:10,high?120:60,high?120:60); }
static void CPUthermalApplyLink(CADisplayLink *link) {
    if(!link)return; BOOL high=CPUthermalShouldForce120();
    if([link respondsToSelector:@selector(setPreferredFrameRateRange:)])link.preferredFrameRateRange=CPUthermalRange(high);
    else if([link respondsToSelector:@selector(setPreferredFramesPerSecond:)])link.preferredFramesPerSecond=high?120:60;
    SEL reason=NSSelectorFromString(S("setHighFrameRateReason:")); if(high&&[link respondsToSelector:reason])((void(*)(id,SEL,BOOL))objc_msgSend)(link,reason,YES);
}
static void CPUthermalSetFloat(id obj,const char *name,float value){SEL sel=NSSelectorFromString(S(name));if(obj&&[obj respondsToSelector:sel])((void(*)(id,SEL,float))objc_msgSend)(obj,sel,value);}
static void CPUthermalApplyWindowServer(void) {
    if(!CPUthermalShouldForce120())return; Class cls=NSClassFromString(S("CAWindowServer"));SEL serverSel=NSSelectorFromString(S("server"));id server=[cls respondsToSelector:serverSel]?((id(*)(id,SEL))objc_msgSend)(cls,serverSel):nil;SEL displaysSel=NSSelectorFromString(S("displays"));NSArray *displays=[server respondsToSelector:displaysSel]?((id(*)(id,SEL))objc_msgSend)(server,displaysSel):nil;
    for(id display in displays){SEL allow=NSSelectorFromString(S("setAllowsVirtualModes:"));if([display respondsToSelector:allow])((void(*)(id,SEL,BOOL))objc_msgSend)(display,allow,YES);CPUthermalSetFloat(display,"setMinimumRefreshRate:",120);CPUthermalSetFloat(display,"setMaximumRefreshRate:",120);CPUthermalSetFloat(display,"setIdealRefreshRate:",120);}
}
static void CPUthermalApplyAll(void) {
    dispatch_async(dispatch_get_main_queue(),^{for(CADisplayLink *link in gDisplayLinks)CPUthermalApplyLink(link);CPUthermalApplyLink(gPersistentLink);if(CPUthermalShouldForce120()){gDriverLayer.speed=1.0;CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:S("opacity")];a.fromValue=@0.01;a.toValue=@0.011;a.duration=1;a.repeatCount=INFINITY;a.removedOnCompletion=NO;[gDriverLayer addAnimation:a forKey:S("CPUthermalProMotion120")];CPUthermalApplyWindowServer();}else [gDriverLayer removeAnimationForKey:S("CPUthermalProMotion120")];});
}
static void CPUthermalReloadState(void) {
    BOOL force=NO;CPUthermalReadRefreshRateState(&force);atomic_store(&gForce120,force);CPUthermalApplyAll();
}
static void CPUthermalRefreshChanged(CFNotificationCenterRef c,void *o,CFStringRef n,const void *x,CFDictionaryRef u){CPUthermalReloadState();}

%hook UIScreen
- (NSInteger)maximumFramesPerSecond { return CPUthermalShouldForce120()?120:%orig; }
%end
%hook CADisplayLink
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector { CADisplayLink *link=%orig;[gDisplayLinks addObject:link];CPUthermalApplyLink(link);return link; }
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range { if(CPUthermalShouldForce120())%orig(CAFrameRateRangeMake(10,120,120));else %orig; }
- (void)setPreferredFramesPerSecond:(NSInteger)fps { if(CPUthermalShouldForce120())%orig(120);else %orig; }
- (void)setFrameInterval:(NSInteger)interval { if(CPUthermalShouldForce120())%orig(1);else %orig; }
%end
%hook CAMutableDisplayPreferences
- (void)setPreferredRefreshRate:(double)rate { if(CPUthermalShouldForce120())%orig(120.0);else %orig; }
%end
%hook CADisplayPreferences
- (void)setPreferredRefreshRate:(double)rate { if(CPUthermalShouldForce120())%orig(120.0);else %orig; }
%end
%hook CADisplay
- (void)setPreferences:(id)prefs { if(CPUthermalShouldForce120()&&prefs)@try{[prefs setValue:@120.0 forKey:S("preferredRefreshRate")];}@catch(__unused NSException *e){} %orig; }
%end
%hook CAContext
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range { if(CPUthermalShouldForce120()){range.maximum=120;range.preferred=120;}%orig(range); }
- (void)setPreferredFrameRate:(float)rate { if(CPUthermalShouldForce120()&&rate>=60)%orig(120);else %orig; }
%end
%hook CADynamicFrameRateSource
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range { if(CPUthermalShouldForce120())range=CAFrameRateRangeMake(120,120,120);%orig(range); }
- (CAFrameRateRange)preferredFrameRateRange { CAFrameRateRange range=%orig;if(CPUthermalShouldForce120())range=CAFrameRateRangeMake(120,120,120);return range; }
%end
%hook CAFrameRateRangeGroup
- (CAFrameRateRange)arbitratedRange { CAFrameRateRange range=%orig;if(CPUthermalShouldForce120())range=CAFrameRateRangeMake(120,120,120);return range; }
%end

%ctor { @autoreleasepool {
    gDisplayLinks=[NSHashTable weakObjectsHashTable];
    CPUthermalReloadState();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,CPUthermalRefreshChanged,(__bridge CFStringRef)S(kCPUthermalRefreshRateNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    if([NSBundle.mainBundle.bundleIdentifier isEqualToString:S("com.apple.springboard")])dispatch_async(dispatch_get_main_queue(),^{gDriverLayer=[CALayer layer];gDriverLayer.opacity=0.01;gPersistentLink=[CADisplayLink displayLinkWithTarget:gDriverLayer selector:@selector(setNeedsDisplay)];[gPersistentLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];CPUthermalApplyAll();});
} }
