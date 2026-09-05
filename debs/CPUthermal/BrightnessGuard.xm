#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <CPUthermalPaths.h>

static void (*origSetBrightnessProperty)(id,SEL,id,id)=NULL;
static id gBrightnessClient=nil;
static BOOL gApplyingBrightness=NO;
static CFAbsoluteTime gLastCorrection=0;

static BOOL GuardEnabled(void){return [CPUthermalReadPrefs()[S("thermalPreventDimmingEnabled")] boolValue];}

static void CorrectPhysicalBrightness(void){
    if(!GuardEnabled()||CPUthermalScreenIsBlanked()||gApplyingBrightness)return;
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();if(now-gLastCorrection<0.75)return;
    Class cls=objc_getClass("BrightnessSystemClient");if(!cls)return;
    if(!gBrightnessClient)gBrightnessClient=[[cls alloc]init];
    SEL copy=sel_registerName("copyPropertyForKey:"),set=sel_registerName("setProperty:forKey:");
    if(![gBrightnessClient respondsToSelector:copy]||![gBrightnessClient respondsToSelector:set])return;
    NSDictionary *display=((id(*)(id,SEL,id))objc_msgSend)(gBrightnessClient,copy,S("DisplayBrightness"));
    NSDictionary *limits=((id(*)(id,SEL,id))objc_msgSend)(gBrightnessClient,copy,S("VirtualBrightnessLimits"));
    double slider=[display[S("Brightness")] doubleValue];
    double physical=[display[S("NitsPhysical")] doubleValue];
    double userMax=[limits[S("UserAccessibleMaxNits")] doubleValue];
    if(userMax<=0.0)userMax=[limits[S("HardwareAccessibleMaxNits")] doubleValue];
    if(slider<0.80||physical<=0.0||userMax<=0.0)return;
    double expected=userMax*(slider>=0.98?1.0:slider);
    if(physical>=expected*0.78)return;
    gLastCorrection=now;gApplyingBrightness=YES;
    NSDictionary *request=slider>=0.98?@{S("Nits"):@(userMax),S("Commit"):@YES}:@{S("Brightness"):@(slider),S("Commit"):@YES};
    ((void(*)(id,SEL,id,id))objc_msgSend)(gBrightnessClient,set,request,S("DisplayBrightness"));
    gApplyingBrightness=NO;
}

static void HookedSetBrightnessProperty(id self,SEL selector,id property,id key){
    if(origSetBrightnessProperty)origSetBrightnessProperty(self,selector,property,key);
    if(gApplyingBrightness||![key isKindOfClass:[NSString class]]||![key isEqualToString:S("DisplayBrightness")])return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60ull*NSEC_PER_MSEC),dispatch_get_main_queue(),^{CorrectPhysicalBrightness();});
}

static void InstallBrightnessHook(void){
    if(origSetBrightnessProperty)return;
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",RTLD_NOW|RTLD_LOCAL);
    Class cls=objc_getClass("BrightnessSystemClient");SEL selector=sel_registerName("setProperty:forKey:");
    Method method=cls?class_getInstanceMethod(cls,selector):NULL;
    if(method&&method_getNumberOfArguments(method)==4)MSHookMessageEx(cls,selector,(IMP)HookedSetBrightnessProperty,(IMP*)&origSetBrightnessProperty);
}

%ctor{
    @autoreleasepool{dispatch_async(dispatch_get_main_queue(),^{
        InstallBrightnessHook();CorrectPhysicalBrightness();
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer){InstallBrightnessHook();CorrectPhysicalBrightness();}];
    });}
}
