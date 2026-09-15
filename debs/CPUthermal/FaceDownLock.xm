#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CPUthermalPaths.h>

@interface SpringBoard : UIApplication
+ (instancetype)sharedApplication;
- (void)_simulateLockButtonPress;
@end

static BOOL gFaceDownLockEnabled = NO;
static CFAbsoluteTime gLastFaceDownLockTime = 0;
static int gFaceDownSettingsToken = 0;

static void ReloadFaceDownPreference(void) {
    gFaceDownLockEnabled = [CPUthermalReadPrefs()[S("lockWhenFaceDown")] boolValue];
}

// --- 注销(Respring)后的亮度自检 ---
// SpringBoard 每次(重新)加载都会执行一次：重新提交当前用户滑块亮度，
// 让被温控压低/卡住的显示亮度回到用户设定值。
static BOOL CPUthermalBrightnessProtectionConfigured(void) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    return [prefs[S("enabled")] boolValue] && [prefs[S("thermalPreventDimmingEnabled")] boolValue];
}

static void CPUthermalSpringBoardBrightnessCheck(void) {
    if (!CPUthermalBrightnessProtectionConfigured()) return;
    const char *paths[]={"/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                         "/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness",NULL};
    BOOL loaded = NO;
    for (int i=0;paths[i];i++) if (dlopen(paths[i], RTLD_NOW|RTLD_LOCAL)) { loaded = YES; break; }
    if (!loaded) return;
    Class clientClass = objc_getClass("BrightnessSystemClient");
    if (!clientClass) return;
    id client = nil;
    @try { client = [[clientClass alloc] init]; } @catch (__unused NSException *e) { return; }
    if (!client) return;
    SEL copySel = NSSelectorFromString(S("copyPropertyForKey:"));
    SEL setSel = NSSelectorFromString(S("setProperty:forKey:"));
    if (![client respondsToSelector:copySel] || ![client respondsToSelector:setSel]) return;
    id display = nil;
    @try { display = ((id(*)(id,SEL,id))objc_msgSend)(client, copySel, S("DisplayBrightness")); }
    @catch (__unused NSException *e) { display = nil; }
    if (![display isKindOfClass:[NSDictionary class]]) return;
    id brightness = [(NSDictionary *)display objectForKey:S("Brightness")];
    if (![brightness respondsToSelector:@selector(doubleValue)]) return;
    double value = [brightness doubleValue];
    if (value <= 0.0 || value > 1.0) return;
    NSDictionary *request = @{S("Brightness"): brightness, S("Commit"): @YES};
    @try { ((void(*)(id,SEL,id,id))objc_msgSend)(client, setSel, request, S("DisplayBrightness")); }
    @catch (__unused NSException *e) { }
}

%hook SBIdleTimerGlobalStateMonitor
- (void)pocketStateMonitor:(id)monitor pocketStateDidChangeFrom:(long long)oldState to:(long long)newState {
    %orig;
    if (!gFaceDownLockEnabled || newState != 3) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastFaceDownLockTime < 1.5) return;
    gLastFaceDownLockTime = now;
    id springBoard = [%c(SpringBoard) sharedApplication];
    if ([springBoard respondsToSelector:@selector(_simulateLockButtonPress)])
        [springBoard _simulateLockButtonPress];
}
%end

%ctor {
    @autoreleasepool {
        ReloadFaceDownPreference();
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gFaceDownSettingsToken,
                                 dispatch_get_main_queue(), ^(int token) {
            (void)token;
            ReloadFaceDownPreference();
        });
        // 注销/重载 SpringBoard 后各跑一次亮度自检（覆盖“亮度被压低后注销也不恢复”）。
        const double delays[] = {1.5, 5.0};
        for (NSUInteger i = 0; i < sizeof(delays)/sizeof(delays[0]); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i]*NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                CPUthermalSpringBoardBrightnessCheck();
            });
        }
    }
}
