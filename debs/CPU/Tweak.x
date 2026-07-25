#import "CPUthermalHelper.h"
#import <notify.h>

// notify.h 通知名（与 CPUthermalPrefs.m 同步）
#define kCPUthermalReloadNotifyName  "com.huayuarc.cputhermal.reloadPrefs"

// ============================================================
// 根据当前偏好设置 thermalmonitord 的工作模式
// ============================================================
static void CPUthermalApplyMode(void) {
    CPUthermalHelper *helper = CPUthermalHelper.shared;
    [helper reloadPrefs];

    if (!helper.commonProductObject) {
        NSLog(@"[CPUthermal] commonProductObject 为空，跳过 putDeviceInThermalSimulationMode");
        return;
    }

    if ([helper.thermalPowerMode isEqualToString:@"lowPower"]) {
        // 低功耗：模拟中度热压力，触发系统主动降频
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"moderate"];
        NSLog(@"[CPUthermal] 模式: 低功耗 (moderate)");
    } else {
        // 解除温控：恢复 Apple 原生温控策略
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"nominal"];
        NSLog(@"[CPUthermal] 模式: 解除温控 (nominal)");
    }

    // 强制触发 CommonProduct 重新评估
    if ([helper.commonProductObject respondsToSelector:@selector(tryTakeAction)]) {
        [helper.commonProductObject tryTakeAction];
    }
}

// ============================================================
// CommonProduct - 初始化时注入helper并应用模式
// ============================================================
// 供 LowPowerHooks.x 引用的 CommonProduct 实例
__attribute__((visibility("default"))) CommonProduct *g_lp_commonProduct = nil;

%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
    g_lp_commonProduct = self;
    CPUthermalApplyMode();
    return res;
}

%end

// ============================================================
// NSDictionary - 修补温控配置文件（防温控暗屏）
// ============================================================
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
    id res = %orig(path);
    if ([path containsString:@"/System/Library/ThermalMonitor/"]) {
        if ([res isKindOfClass:[NSDictionary class]]) {
            CFDictionaryRef patched = [CPUthermalHelper.shared patchThermalPlist:(__bridge CFDictionaryRef)res];
            return (__bridge id)patched;
        }
    }
    return res;
}

%end

// ============================================================
// Darwin notification callback for puppet event
// ============================================================
static void puppetEventCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [CPUthermalHelper.shared executePuppetEvent];
}

// ============================================================
// Darwin notification callback for preference reload
// ============================================================
static void reloadPrefsCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CPUthermalApplyMode();
}

%ctor {
    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(
        nc,
        NULL,
        puppetEventCallback,
        CFSTR("com.huayuarc.cputhermal-executePuppetEvent"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 监听偏好重载通知（如 CPU 模式切换）
    CFNotificationCenterAddObserver(
        nc,
        NULL,
        reloadPrefsCallback,
        CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 备用通道: notify.h 通知
    int token;
    notify_register_dispatch(kCPUthermalReloadNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
        CPUthermalApplyMode();
    });
}
