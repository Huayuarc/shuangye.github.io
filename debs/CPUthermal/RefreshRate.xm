#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

// 参考 ProMotion120：SpringBoard 使用显示服务器双路径，第三方应用启用 UIScreen、
// CADisplayLink、Metal、CAContext 与动态帧率源全局 Hook。
static atomic_bool gForce120=false;
static atomic_bool gCaptured=false;
static BOOL gSpringBoard=NO;
static BOOL gThirdPartyApp=NO;
static CADisplayLink *gLink=nil;
static CALayer *gLayer=nil;
static NSTimer *gReassertTimer=nil;

@interface CADisplay : NSObject
+ (id)mainDisplay;
- (NSArray *)availableModes;
@end

static BOOL Supports120(void) {
    static dispatch_once_t once; static BOOL supported=NO;
    dispatch_once(&once, ^{
        @try {
            Class c=NSClassFromString(S("CADisplay"));
            id display=[c respondsToSelector:@selector(mainDisplay)]?((id(*)(id,SEL))objc_msgSend)(c,@selector(mainDisplay)):nil;
            NSArray *modes=[display respondsToSelector:@selector(availableModes)]?((id(*)(id,SEL))objc_msgSend)(display,@selector(availableModes)):nil;
            for(id mode in modes) if([[mode valueForKey:S("refreshRate")] doubleValue]>=119.0){supported=YES;break;}
            if(!supported && UIScreen.mainScreen.maximumFramesPerSecond>=120)supported=YES;
        } @catch(__unused NSException *e) {}
    });
    return supported;
}

static BOOL ShouldUse120(void) {
    return gSpringBoard && atomic_load(&gForce120) && !atomic_load(&gCaptured) && Supports120();
}

static void SetRate(id object,const char *name,double value) {
    SEL selector=NSSelectorFromString(S(name));
    if(!object || ![object respondsToSelector:selector])return;
    Method method=class_getInstanceMethod(object_getClass(object),selector);
    char type[16]={0}; if(method)method_getArgumentType(method,2,type,sizeof(type));
    const char *p=type;while(*p&&strchr("rnNoORV",*p))p++;
    if(*p=='d')((void(*)(id,SEL,double))objc_msgSend)(object,selector,value);
    else if(*p=='f')((void(*)(id,SEL,float))objc_msgSend)(object,selector,(float)value);
    else if(strchr("qQiIlLsS",*p))((void(*)(id,SEL,long long))objc_msgSend)(object,selector,(long long)value);
}

static void ApplyDisplayServer120(void) {
    if(!ShouldUse120())return;
    @try {
        Class c=NSClassFromString(S("CAWindowServer")); SEL serverSelector=NSSelectorFromString(S("server"));
        id server=[c respondsToSelector:serverSelector]?((id(*)(id,SEL))objc_msgSend)(c,serverSelector):nil;
        SEL displaysSelector=NSSelectorFromString(S("displays"));
        NSArray *displays=[server respondsToSelector:displaysSelector]?((id(*)(id,SEL))objc_msgSend)(server,displaysSelector):nil;
        for(id display in displays) {
            SEL virtualSelector=NSSelectorFromString(S("setAllowsVirtualModes:"));
            if([display respondsToSelector:virtualSelector])((void(*)(id,SEL,BOOL))objc_msgSend)(display,virtualSelector,YES);
            SetRate(display,"setMinimumRefreshRate:",120.0f);
            SetRate(display,"setMaximumRefreshRate:",120.0f);
            SetRate(display,"setIdealRefreshRate:",120.0f);
            SetRate(display,"setPreferredRefreshRate:",120.0f);
        }
        // 附件中的 CADisplayPreferences 路径以动态 selector 补充，不安装全局 Hook。
        Class displayClass=NSClassFromString(S("CADisplay"));
        id mainDisplay=[displayClass respondsToSelector:@selector(mainDisplay)]?((id(*)(id,SEL))objc_msgSend)(displayClass,@selector(mainDisplay)):nil;
        SetRate(mainDisplay,"setPreferredRefreshRate:",120.0f);
    } @catch(__unused NSException *e) {}
}

static void Apply(void) {
    if(!gSpringBoard)return;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL high=ShouldUse120();
        if(gLink) {
            gLink.paused=!high;
            if(high) {
                if([gLink respondsToSelector:@selector(setPreferredFrameRateRange:)])
                    gLink.preferredFrameRateRange=CAFrameRateRangeMake(120,120,120);
                else gLink.preferredFramesPerSecond=0;
            }
        }
        if(!high){[gLayer removeAnimationForKey:S("CPUthermalProMotion120")];return;}
        CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:S("opacity")];
        a.fromValue=@0.01;a.toValue=@0.011;a.duration=1;a.repeatCount=INFINITY;a.removedOnCompletion=NO;
        [gLayer addAnimation:a forKey:S("CPUthermalProMotion120")];
        ApplyDisplayServer120();
    });
}

static void Reload(void) {
    BOOL force=NO;
    if(!CPUthermalReadRefreshRateState(&force)) {
        force=[CPUthermalReadPrefs()[S("force120HzEnable")] boolValue];
        CPUthermalPostRefreshRateState(force);
    }
    atomic_store(&gForce120,force); Apply();
}

static void Changed(CFNotificationCenterRef c,void *o,CFNotificationName n,const void*x,CFDictionaryRef u){(void)c;(void)o;(void)n;(void)x;(void)u;Reload();}
static void CaptureChanged(NSNotification *note){(void)note;atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);Apply();}
static BOOL ShouldHookApp120(void){return gThirdPartyApp&&atomic_load(&gForce120)&&!atomic_load(&gCaptured)&&Supports120();}
static void ForceDisplayLink(CADisplayLink *link){
    if(!link||!ShouldHookApp120())return;
    if([link respondsToSelector:@selector(setPreferredFrameRateRange:)])link.preferredFrameRateRange=CAFrameRateRangeMake(120,120,120);
    else link.preferredFramesPerSecond=0;
}

@interface CAMetalLayer (CPUthermal120)
@property(assign) NSUInteger maximumDrawableCount;
@end
@interface CAContext : NSObject @end
@interface CADynamicFrameRateSource : NSObject @end

%group CPUthermalThirdParty120
%hook UIScreen
- (NSInteger)maximumFramesPerSecond{return ShouldHookApp120()?120:%orig;}
%end

%hook CADisplayLink
+ (id)displayLinkWithTarget:(id)target selector:(SEL)selector{id link=%orig;ForceDisplayLink(link);return link;}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range{if(ShouldHookApp120())%orig(CAFrameRateRangeMake(120,120,120));else %orig(range);}
- (void)setPreferredFramesPerSecond:(NSInteger)fps{if(ShouldHookApp120())%orig(0);else %orig(fps);}
- (void)setFrameInterval:(NSInteger)interval{if(ShouldHookApp120())%orig(1);else %orig(interval);}
%end

%hook CAMetalLayer
- (NSUInteger)maximumDrawableCount{NSUInteger value=%orig;return ShouldHookApp120()&&value<3?3:value;}
%end

%hook CAMetalDrawable
- (void)presentAfterMinimumDuration:(CFTimeInterval)duration{if(ShouldHookApp120())%orig(1.0/120.0);else %orig(duration);}
%end

%hook MTLCommandBuffer
- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)duration{if(ShouldHookApp120())%orig(drawable,1.0/120.0);else %orig(drawable,duration);}
%end

%hook CAContext
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range{if(ShouldHookApp120())%orig(CAFrameRateRangeMake(120,120,120));else %orig(range);}
- (void)setPreferredFrameRate:(float)rate{if(ShouldHookApp120()&&rate>=60.0f)%orig(120.0f);else %orig(rate);}
%end

%hook CADynamicFrameRateSource
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range{if(ShouldHookApp120())%orig(CAFrameRateRangeMake(120,120,120));else %orig(range);}
- (CAFrameRateRange)preferredFrameRateRange{CAFrameRateRange range=%orig;return ShouldHookApp120()?CAFrameRateRangeMake(120,120,120):range;}
%end
%end

static BOOL IsThirdPartyApplication(void){
    NSString *bundleID=NSBundle.mainBundle.bundleIdentifier?:S("");
    if(!bundleID.length||[bundleID hasPrefix:S("com.apple.")])return NO;
    NSString *path=NSBundle.mainBundle.bundlePath?:S("");
    return [path rangeOfString:S("/Bundle/Application/") options:NSCaseInsensitiveSearch].location!=NSNotFound||
           [path rangeOfString:S("/Applications/") options:NSCaseInsensitiveSearch].location!=NSNotFound;
}

%ctor { @autoreleasepool {
    gSpringBoard=[NSBundle.mainBundle.bundleIdentifier isEqualToString:S("com.apple.springboard")];
    gThirdPartyApp=IsThirdPartyApplication();
    if(!gSpringBoard&&!gThirdPartyApp)return;
    // 在安装 UIScreen Hook 前缓存原生能力，避免 maximumFramesPerSecond 自调用。
    BOOL supports=Supports120();
    if(gThirdPartyApp&&supports)%init(CPUthermalThirdParty120);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((gSpringBoard?1.0:0.0)*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        @try {
            atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);
            CFNotificationCenterRef c=CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(c,NULL,Changed,(__bridge CFStringRef)S(kCPUthermalRefreshRateNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(c,NULL,Changed,(__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            [NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){CaptureChanged(n);}];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){Reload();}];
            if(gSpringBoard){
                gLayer=[CALayer layer];gLayer.opacity=0.01;
                gLink=[CADisplayLink displayLinkWithTarget:gLayer selector:@selector(setNeedsDisplay)];
                [gLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
                gReassertTimer=[NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer){if(ShouldUse120())ApplyDisplayServer120();}];
            }
            Reload();
        } @catch(__unused NSException *e) {}
    });
} }
