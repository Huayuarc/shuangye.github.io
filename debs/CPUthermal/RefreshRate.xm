#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

// Filter 保留 UIKit/SpringBoard/通知 UI；仅 SpringBoard 请求全局刷新率。
// 不 Hook UIScreen、CADisplayLink、CAContext 等应用渲染对象，避免掉帧和 UI 调度冲突。
static atomic_bool gForce120 = false;
static atomic_bool gProtection = true;
static atomic_bool gCaptured = false;
static BOOL gSpringBoard = NO;
static CADisplayLink *gLink = nil;
static CALayer *gLayer = nil;

@interface CADisplay : NSObject
+ (id)mainDisplay;
- (NSArray *)availableModes;
@end

static BOOL Supports120(void) {
    static dispatch_once_t once;
    static BOOL supported = NO;
    dispatch_once(&once, ^{
        @try {
            Class c=NSClassFromString(S("CADisplay"));
            id d=[c respondsToSelector:@selector(mainDisplay)] ? ((id(*)(id,SEL))objc_msgSend)(c,@selector(mainDisplay)) : nil;
            NSArray *m=[d respondsToSelector:@selector(availableModes)] ? ((id(*)(id,SEL))objc_msgSend)(d,@selector(availableModes)) : nil;
            for(id x in m) if([[x valueForKey:S("refreshRate")] doubleValue]>=119.0){supported=YES;break;}
            if(!supported&&UIScreen.mainScreen.maximumFramesPerSecond>=120)supported=YES;
        } @catch(__unused NSException *e) {}
    });
    return supported;
}
static BOOL ShouldUse120(void) {
    if(!gSpringBoard || !atomic_load(&gForce120) || atomic_load(&gCaptured) || !Supports120())return NO;
    if(!atomic_load(&gProtection))return YES;
    NSProcessInfoThermalState state=NSProcessInfo.processInfo.thermalState;
    return state!=NSProcessInfoThermalStateSerious && state!=NSProcessInfoThermalStateCritical;
}
static void SetRate(id object,const char *name,float value) {
    SEL s=NSSelectorFromString(S(name));
    if(object&&[object respondsToSelector:s])((void(*)(id,SEL,float))objc_msgSend)(object,s,value);
}
static void ApplyWindowServer(void) {
    if(!ShouldUse120())return;
    Class c=NSClassFromString(S("CAWindowServer")); SEL s=NSSelectorFromString(S("server"));
    id server=[c respondsToSelector:s]?((id(*)(id,SEL))objc_msgSend)(c,s):nil;
    SEL ds=NSSelectorFromString(S("displays")); NSArray *displays=[server respondsToSelector:ds]?((id(*)(id,SEL))objc_msgSend)(server,ds):nil;
    for(id display in displays) {
        SEL vm=NSSelectorFromString(S("setAllowsVirtualModes:"));
        if([display respondsToSelector:vm])((void(*)(id,SEL,BOOL))objc_msgSend)(display,vm,YES);
        SetRate(display,"setMinimumRefreshRate:",120); SetRate(display,"setMaximumRefreshRate:",120); SetRate(display,"setIdealRefreshRate:",120);
    }
}
static void Apply(void) {
    if(!gSpringBoard)return;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL high=ShouldUse120();
        if(gLink){gLink.paused=!high; if(high)gLink.preferredFrameRateRange=CAFrameRateRangeMake(120,120,120);}
        if(!high){[gLayer removeAnimationForKey:S("CPUthermalProMotion120")];return;}
        CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:S("opacity")];
        a.fromValue=@0.01; a.toValue=@0.011; a.duration=1; a.repeatCount=INFINITY; a.removedOnCompletion=NO;
        [gLayer addAnimation:a forKey:S("CPUthermalProMotion120")]; ApplyWindowServer();
    });
}
static void Reload(void) {
    BOOL force=NO, protection=YES;
    if(!CPUthermalReadRefreshRateState(&force,&protection)) {
        NSDictionary *p=CPUthermalReadPrefs()?:@{}; force=[p[S("force120HzEnable")] boolValue];
        id raw=p[S("refreshThermalProtectionEnabled")]; protection=raw?[raw boolValue]:YES;
        CPUthermalPostRefreshRateState(force,protection);
    }
    atomic_store(&gForce120,force); atomic_store(&gProtection,protection); Apply();
}
static void Changed(CFNotificationCenterRef c,void *o,CFNotificationName n,const void*x,CFDictionaryRef u){(void)c;(void)o;(void)n;(void)x;(void)u;Reload();}
static void CaptureChanged(NSNotification *note){(void)note;atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);Apply();}

%ctor { @autoreleasepool {
    // Filter 可包含多个系统 Bundle；只有 SpringBoard 执行显示服务器逻辑。
    // UIKit/通知宿主不读 UIScreen、不创建 DisplayLink、不注册 UIKit 通知，避免启动期崩溃。
    gSpringBoard=[NSBundle.mainBundle.bundleIdentifier isEqualToString:S("com.apple.springboard")];
    if(!gSpringBoard)return;

    // SpringBoard 启动早期 CAWindowServer/UIScreen 尚未稳定；延迟初始化后再请求 120Hz。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        @try {
            atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);
            CFNotificationCenterRef c=CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(c,NULL,Changed,(__bridge CFStringRef)S(kCPUthermalRefreshRateNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(c,NULL,Changed,(__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            [NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){CaptureChanged(note);}];
            gLayer=[CALayer layer]; gLayer.opacity=0.01;
            gLink=[CADisplayLink displayLinkWithTarget:gLayer selector:@selector(setNeedsDisplay)];
            [gLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            Reload();
        } @catch(__unused NSException *exception) {}
    });
} }
