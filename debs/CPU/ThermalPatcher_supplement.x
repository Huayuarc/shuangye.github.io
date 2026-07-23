#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include "CPUthermalPaths.h"

// ============================================================================
// ThermalPatcher_supplement — thermalmonitord 进程补充钩子
//
// 本文件使用 C 函数手动 MSHookMessageEx，不依赖 Theos %hook 语法。
// 仅包含 thermalmonitord 进程内有效的类钩子。
//
// SpringBoard 专属钩子（SBBrightnessController / CSDevice / Launchd）
// 已移至 Tweak_SB.x。
// ============================================================================

// ============================================================================
// 私有类声明
// ============================================================================
@interface ThermalMonitor : NSObject
- (id)thermalMitigationData;
@end

@interface DVFSController : NSObject
- (NSInteger)maxSupportedFrequency;
- (void)applyThermalThrottling;
@end

// ============================================================================
// Hook 实现前向声明
// ============================================================================
static id imp_thermalMitigationData(id self, SEL _cmd);
static NSInteger imp_maxSupportedFreq(id self, SEL _cmd);
static void imp_applyThrottle(id self, SEL _cmd);

// ============================================================================
// 全局变量（同步主 tweak 状态）
// ============================================================================
static BOOL gSup_enabled = NO;
static BOOL gSup_cpuProtection = NO;
static NSString *gSup_powerMode = nil;

// ============================================================================
// Hook 原函数指针
// ============================================================================
static id (*orig_thermalMitigationData)(id self, SEL _cmd);
static NSInteger (*orig_maxSupportedFreq)(id self, SEL _cmd);
static void (*orig_applyThrottle)(id self, SEL _cmd);

// 日志
#define CT_LOG(fmt, ...) NSLog(@"[CPUthermal-supplement] " fmt, ##__VA_ARGS__)

static void Sup_loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = CPUthermalReadPrefs() ?: [NSDictionary dictionary];
        gSup_enabled = [d[S("enabled")] ?: [NSNumber numberWithBool:NO] boolValue];
        gSup_cpuProtection = gSup_enabled && [d[S("cpuProtection")] ?: [NSNumber numberWithBool:YES] boolValue];
        gSup_powerMode = [d[S("powerMode")] isKindOfClass:[NSString class]] ? d[S("powerMode")] : S("fullPower");
    }
}

static void Sup_onSettingsChanged(CFNotificationCenterRef center, void *observer,
                                   CFNotificationName name, const void *object,
                                   CFDictionaryRef userInfo) {
    Sup_loadPrefs();
    CT_LOG(@"设置已重载: enabled=%d cpuProtection=%d powerMode=%@",
           gSup_enabled, gSup_cpuProtection, gSup_powerMode);
}

// ============================================================================
// Hook 实现
// ============================================================================

// ThermalMonitor — 热缓解策略数据拦截
static id imp_thermalMitigationData(id self, SEL _cmd) {
    if (gSup_enabled && gSup_cpuProtection && [gSup_powerMode isEqualToString:S("fullPower")]) {
        CT_LOG(@"已屏蔽系统热缓解策略数据");
        return nil;
    }
    return orig_thermalMitigationData ? orig_thermalMitigationData(self, _cmd) : nil;
}

// DVFSController — 锁定原生最高频率（解除温控模式下）
static NSInteger imp_maxSupportedFreq(id self, SEL _cmd) {
    NSInteger result = orig_maxSupportedFreq ? orig_maxSupportedFreq(self, _cmd) : 0;
    if (gSup_enabled && gSup_cpuProtection && [gSup_powerMode isEqualToString:S("fullPower")]) {
        NSInteger nativeMax = CPUthermalNativeMaxPCoreFrequencyMHz();
        CT_LOG(@"DVFS 最大频率 %ld -> %ld (原生)", (long)result, (long)nativeMax);
        return nativeMax;
    }
    return result;
}

// DVFSController — 拦截温控降频调用
static void imp_applyThrottle(id self, SEL _cmd) {
    if (gSup_enabled && gSup_cpuProtection) {
        CT_LOG(@"拦截 DVFS 温控降频调用");
        return;
    }
    if (orig_applyThrottle) {
        orig_applyThrottle(self, _cmd);
    }
}

// ============================================================================
// 初始化
// ============================================================================
static void __attribute__((constructor)) initThermalSupplementHook(void) {
    @autoreleasepool {
        Sup_loadPrefs();

        Class ThermalMonitor = objc_getClass("ThermalMonitor");
        Class DVFSController = objc_getClass("DVFSController");

        // 1. ThermalMonitor — 热缓解数据拦截
        if (ThermalMonitor) {
            MSHookMessageEx(ThermalMonitor, @selector(thermalMitigationData),
                (IMP)imp_thermalMitigationData, (IMP *)&orig_thermalMitigationData);
            CT_LOG(@"ThermalMonitor.thermalMitigationData hook 已安装");
        }

        // 2. DVFSController — 调频/温控降频拦截
        if (DVFSController) {
            MSHookMessageEx(DVFSController, @selector(maxSupportedFrequency),
                (IMP)imp_maxSupportedFreq, (IMP *)&orig_maxSupportedFreq);
            MSHookMessageEx(DVFSController, @selector(applyThermalThrottling),
                (IMP)imp_applyThrottle, (IMP *)&orig_applyThrottle);
            CT_LOG(@"DVFSController hooks 已安装");
        }

        // 3. 注册通知监听
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            CFNotificationCenterAddObserver(c, NULL, Sup_onSettingsChanged,
                (__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(c, NULL, Sup_onSettingsChanged,
                (__bridge CFStringRef)S(kCPUthermalPowerModeChangedNotifC),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        CT_LOG(@"初始化完成: enabled=%d cpuProtection=%d powerMode=%@",
               gSup_enabled, gSup_cpuProtection, gSup_powerMode);
    }
}
