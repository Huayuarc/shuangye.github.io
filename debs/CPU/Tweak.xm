#import "CPUthermalHelper.h"

// ============================================================
// 应用解除温控模式 - 恢复 Apple 原生温控策略
// ============================================================
static void CPUthermalApplyMode(void) {
    CPUthermalHelper *helper = CPUthermalHelper.shared;

    if (!helper.commonProductObject) return;

    // 始终恢复 Apple 原生温控策略
    [helper.commonProductObject putDeviceInThermalSimulationMode:@"nominal"];
}

// ============================================================
// CommonProduct - 初始化时注入helper并应用模式
// ============================================================
%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
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
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        puppetEventCallback,
        CFSTR("com.huayuarc.cputhermal-executePuppetEvent"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 监听偏好重载通知（如防温控暗屏开关切换）
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        reloadPrefsCallback,
        CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
