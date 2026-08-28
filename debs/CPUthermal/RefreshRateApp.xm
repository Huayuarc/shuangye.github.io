#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

static atomic_bool gAppForce120=false;
static atomic_bool gAppEnhanced=false;
static atomic_bool gAppCaptured=false;
static int gRefreshToken=0;

static BOOL CPUthermalAppHighAllowed(void){return atomic_load(&gAppForce120)&&!atomic_load(&gAppCaptured);}
static CAFrameRateRange CPUthermalAppRange(void){return atomic_load(&gAppEnhanced)?CAFrameRateRangeMake(120,120,120):CAFrameRateRangeMake(10,120,120);}
static void CPUthermalLoadAppState(void){BOOL force=NO,global=NO,enhanced=NO;CPUthermalReadRefreshRateState(&force,&global,&enhanced);atomic_store(&gAppForce120,force&&global);atomic_store(&gAppEnhanced,enhanced);}
static void CPUthermalAppChanged(CFNotificationCenterRef c,void*o,CFStringRef n,const void*x,CFDictionaryRef u){CPUthermalLoadAppState();}

%group CPUthermalThirdPartyRefreshHooks
%hook UIScreen
- (NSInteger)maximumFramesPerSecond{return CPUthermalAppHighAllowed()?120:%orig;}
%end
%hook CADisplayLink
+ (CADisplayLink*)displayLinkWithTarget:(id)target selector:(SEL)selector{CADisplayLink*link=%orig;if(CPUthermalAppHighAllowed())link.preferredFrameRateRange=CPUthermalAppRange();return link;}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range{if(CPUthermalAppHighAllowed())range=CPUthermalAppRange();%orig(range);}
- (void)setPreferredFramesPerSecond:(NSInteger)fps{if(CPUthermalAppHighAllowed())%orig(120);else %orig;}
- (void)setFrameInterval:(NSInteger)interval{if(CPUthermalAppHighAllowed())%orig(1);else %orig;}
%end
%end

%ctor{@autoreleasepool{
    NSString*bid=NSBundle.mainBundle.bundleIdentifier;NSString*path=NSBundle.mainBundle.bundlePath?:S("");
    BOOL thirdParty=bid.length&&![bid hasPrefix:S("com.apple.")];BOOL normalApp=[[path pathExtension]caseInsensitiveCompare:S("app")]==NSOrderedSame;
    if(!thirdParty||!normalApp||CPUthermalRefreshAppExcluded(bid))return;
    CPUthermalLoadAppState();if(!atomic_load(&gAppForce120))return;
    %init(CPUthermalThirdPartyRefreshHooks);
    atomic_store(&gAppCaptured,UIScreen.mainScreen.isCaptured);
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification*n){atomic_store(&gAppCaptured,UIScreen.mainScreen.isCaptured);}];
    notify_register_dispatch(kCPUthermalRefreshRateNotifC,&gRefreshToken,dispatch_get_main_queue(),^(int token){(void)token;CPUthermalLoadAppState();});
}}
