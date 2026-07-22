#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#include <IOKit/IOKitLib.h>
#include "CPUthermalPaths.h"

// ============================================================================
// 私有类声明（运行时存在时才 hook）
// ============================================================================
@interface ThermalMonitor : NSObject
- (id)thermalMitigationData;
@end

@interface DVFSController : NSObject
- (NSInteger)maxSupportedFrequency;
- (void)applyThermalThrottling;
@end

@interface SBBrightnessController : NSObject
- (void)setBrightnessLevel:(float)level forReason:(int)reason;
@end

@interface Launchd : NSObject
- (BOOL)shouldKeepRunningService:(id)service;
@end

@interface CSDevice : NSObject
- (BOOL)_isThermalStateRestricted;
- (BOOL)_shouldReducePerformance;
@end

// ============================================================================
// Hook 实现前向声明（定义在文件后半部分）
// ============================================================================
static id imp_thermalMitigationData(id self, SEL _cmd);
static NSInteger imp_maxSupportedFreq(id self, SEL _cmd);
static void imp_applyThrottle(id self, SEL _cmd);
static void imp_setBrightness(id self, SEL _cmd, float level, int reason);
static BOOL imp_keepService(id self, SEL _cmd, id service);
static BOOL imp_isThermalRestrict(id self, SEL _cmd);
static BOOL imp_reducePerf(id self, SEL _cmd);

// ============================================================================
// Hook 原函数指针
// ============================================================================
static id (*orig_thermalMitigationData)(id self, SEL _cmd);
static NSInteger (*orig_maxSupportedFreq)(id self, SEL _cmd);
static void (*orig_applyThrottle)(id self, SEL _cmd);
static void (*orig_setBrightness)(id self, SEL _cmd, float level, int reason);
static BOOL (*orig_keepService)(id self, SEL _cmd, id service);
static BOOL (*orig_isThermalRestrict)(id self, SEL _cmd);
static BOOL (*orig_reducePerf)(id self, SEL _cmd);

// 日志开关
#define CPUTHERMAL_LOG_ENABLE 1
#if CPUTHERMAL_LOG_ENABLE
#define CT_LOG(fmt, ...) NSLog(@"[CPUthermal-supplement] " fmt, ##__VA_ARGS__)
#else
#define CT_LOG(fmt, ...)
#endif

static void __attribute__((constructor)) initThermalSupplementHook(void) {
    Class ThermalMonitor = objc_getClass("ThermalMonitor");
    Class DVFSController = objc_getClass("DVFSController");
    Class SBBrightnessController = objc_getClass("SBBrightnessController");
    Class Launchd = objc_getClass("Launchd");
    Class CSDevice = objc_getClass("CSDevice");

    // ========== 1. ThermalMonitor 热缓解数据拦截 ==========
    if (ThermalMonitor) {
        MSHookMessageEx(ThermalMonitor, @selector(thermalMitigationData), (IMP)imp_thermalMitigationData, (IMP *)&orig_thermalMitigationData);
    }

    // ========== 2. DVFSController 调频/温控降频拦截 ==========
    if (DVFSController) {
        MSHookMessageEx(DVFSController, @selector(maxSupportedFrequency), (IMP)imp_maxSupportedFreq, (IMP *)&orig_maxSupportedFreq);
        MSHookMessageEx(DVFSController, @selector(applyThermalThrottling), (IMP)imp_applyThrottle, (IMP *)&orig_applyThrottle);
    }

    // ========== 3. SBBrightness 温控自动降亮度拦截 ==========
    if (SBBrightnessController) {
        MSHookMessageEx(SBBrightnessController, @selector(setBrightnessLevel:forReason:), (IMP)imp_setBrightness, (IMP *)&orig_setBrightness);
    }

    // ========== 4. Launchd 后台服务温控查杀拦截 ==========
    if (Launchd) {
        MSHookMessageEx(Launchd, @selector(shouldKeepRunningService:), (IMP)imp_keepService, (IMP *)&orig_keepService);
    }

    // ========== 5. CSDevice 性能限制状态屏蔽 ==========
    if (CSDevice) {
        MSHookMessageEx(CSDevice, @selector(_isThermalStateRestricted), (IMP)imp_isThermalRestrict, (IMP *)&orig_isThermalRestrict);
        MSHookMessageEx(CSDevice, @selector(_shouldReducePerformance), (IMP)imp_reducePerf, (IMP *)&orig_reducePerf);
    }
}

// ---------------------- Hook 实现 ----------------------
static id imp_thermalMitigationData(id self, SEL _cmd) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    BOOL disableThermalMitigate = [prefs[@"disableThermalMitigate"] boolValue];
    if (disableThermalMitigate) {
        CT_LOG(@"屏蔽系统热缓解策略");
        return nil;
    }
    return orig_thermalMitigationData(self, _cmd);
}

static NSInteger imp_maxSupportedFreq(id self, SEL _cmd) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    BOOL lockMaxFreq = [prefs[@"lockNativeMaxFreq"] boolValue];
    NSInteger nativeMax = CPUthermalNativeMaxPCoreFrequencyMHz();
    if (lockMaxFreq) {
        CT_LOG(@"锁定原生大核最高频率: %ld MHz", nativeMax);
        return nativeMax;
    }
    return orig_maxSupportedFreq(self, _cmd);
}

static void imp_applyThrottle(id self, SEL _cmd) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    BOOL blockDVFSThrottle = [prefs[@"blockDVFSThrottle"] boolValue];
    if (!blockDVFSThrottle) {
        orig_applyThrottle(self, _cmd);
    } else {
        CT_LOG(@"拦截DVFS温控降频调用");
    }
}

static void imp_setBrightness(id self, SEL _cmd, float level, int reason) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    BOOL blockThermalDim = [prefs[@"blockThermalDim"] boolValue];
    // reason=温控降亮度标记
    if (blockThermalDim && reason == 3) {
        CT_LOG(@"拦截温控自动降低屏幕亮度");
        return;
    }
    orig_setBrightness(self, _cmd, level, reason);
}

static BOOL imp_keepService(id self, SEL _cmd, id service) {
    return YES;
}

static BOOL imp_isThermalRestrict(id self, SEL _cmd) {
    return NO;
}

static BOOL imp_reducePerf(id self, SEL _cmd) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    BOOL fullPerfMode = [prefs[@"fullPerformance"] boolValue];
    return fullPerfMode ? NO : orig_reducePerf(self, _cmd);
}
