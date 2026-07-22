#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <CPUthermalPaths.h>

// ============================================================================
// CPUthermalSB — SpringBoard 专用钩子
//
// 用途：
//   1. 屏蔽 CSDevice 热状态限制
//   2. 防止 Launchd 因温控终止后台服务
//
// 注意：禁止使用 @"" ObjC 字符串常量（roothide 重映射问题）
// ============================================================================

// ============================================================================
// 私有类声明
// ============================================================================
@interface CSDevice : NSObject
- (BOOL)_isThermalStateRestricted;
- (BOOL)_shouldReducePerformance;
@end

@interface Launchd : NSObject
- (BOOL)shouldKeepRunningService:(id)service;
@end

// ============================================================================
// 静态变量（通过 CFNotificationCenter Darwin 通知更新）
// ============================================================================
static BOOL gSB_enabled = NO;

// ============================================================================
// 偏好设置读取
// ============================================================================
static NSDictionary *SB_readPrefs(void) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    return prefs ?: [NSDictionary dictionary];
}

static void SB_loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = SB_readPrefs();
        gSB_enabled = [d[S("enabled")] ?: [NSNumber numberWithBool:NO] boolValue];
        NSLog(@"[CPUthermalSB] 设置已加载: enabled=%d",
              gSB_enabled);
    }
}

// ============================================================================
// Darwin 通知回调 — 设置变更时同步
// ============================================================================
static void SB_onSettingsChanged(CFNotificationCenterRef center, void *observer,
                                  CFNotificationName name, const void *object,
                                  CFDictionaryRef userInfo) {
    SB_loadPrefs();
    NSLog(@"[CPUthermalSB] 收到设置变更通知");
}

// ============================================================================
// Hook 实现
// ============================================================================

#pragma mark - CSDevice: 屏蔽热状态限制
static BOOL (*orig_isThermalRestrict)(id self, SEL _cmd);

static BOOL SB_imp_isThermalRestrict(id self, SEL _cmd) {
    if (gSB_enabled) {
        return NO;
    }
    return orig_isThermalRestrict ? orig_isThermalRestrict(self, _cmd) : NO;
}

static BOOL (*orig_reducePerf)(id self, SEL _cmd);

static BOOL SB_imp_reducePerf(id self, SEL _cmd) {
    if (gSB_enabled) {
        // 启用时不降性能
        return NO;
    }
    return orig_reducePerf ? orig_reducePerf(self, _cmd) : NO;
}

#pragma mark - Launchd: 防止温控终止服务
static BOOL (*orig_keepService)(id self, SEL _cmd, id service);

static BOOL SB_imp_keepService(id self, SEL _cmd, id service) {
    return YES;
}

// ============================================================================
// 初始化：Hook 安装
// ============================================================================
__attribute__((constructor)) static void initSBHooks(void) {
    @autoreleasepool {
        SB_loadPrefs();

        Class CSDevice = objc_getClass("CSDevice");
        Class Launchd = objc_getClass("Launchd");

        // 1. CSDevice — 屏蔽系统热状态限制
        if (CSDevice) {
            Method m1 = class_getInstanceMethod(CSDevice, @selector(_isThermalStateRestricted));
            if (m1) {
                orig_isThermalRestrict = (BOOL (*)(id, SEL))method_getImplementation(m1);
                method_setImplementation(m1, (IMP)SB_imp_isThermalRestrict);
                NSLog(@"[CPUthermalSB] CSDevice._isThermalStateRestricted hook 已安装");
            }
            Method m2 = class_getInstanceMethod(CSDevice, @selector(_shouldReducePerformance));
            if (m2) {
                orig_reducePerf = (BOOL (*)(id, SEL))method_getImplementation(m2);
                method_setImplementation(m2, (IMP)SB_imp_reducePerf);
                NSLog(@"[CPUthermalSB] CSDevice._shouldReducePerformance hook 已安装");
            }
        }

        // 2. Launchd — 防止温控终止后台服务
        if (Launchd) {
            Method m = class_getInstanceMethod(Launchd, @selector(shouldKeepRunningService:));
            if (m) {
                orig_keepService = (BOOL (*)(id, SEL, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)SB_imp_keepService);
                NSLog(@"[CPUthermalSB] Launchd.shouldKeepRunningService: hook 已安装");
            }
        }

        // 3. 注册 Darwin 通知监听 — 设置变更时同步
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            CFNotificationCenterAddObserver(c, NULL, SB_onSettingsChanged,
                (__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(c, NULL, SB_onSettingsChanged,
                (__bridge CFStringRef)S(kCPUthermalPowerModeChangedNotifC),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        NSLog(@"[CPUthermalSB] 初始化完成");
    }
}
