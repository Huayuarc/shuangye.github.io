#import "CPUthermalHelper.h"

// ============================================================
// 低功耗模式状态标志（由 Hook 查询，mode 切换时更新）
// ============================================================
static BOOL _cpuLowPowerModeActive = NO;

// ============================================================
// 根据当前偏好设置 thermalmonitord 的工作模式
// ============================================================
static void CPUthermalApplyMode(void) {
    CPUthermalHelper *helper = CPUthermalHelper.shared;
    [helper reloadPrefs];

    if ([helper.thermalPowerMode isEqualToString:@"lowPower"]) {
        // 低功耗：模拟中度热压力 + 强制 MitigationController 降频
        _cpuLowPowerModeActive = YES;
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"moderate"];
    } else {
        // 解除温控：恢复 Apple 原生温控策略
        _cpuLowPowerModeActive = NO;
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"nominal"];
    }
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
// MitigationController - 低功耗模式：强制降频
// ============================================================
%hook MitigationController

// 省电模式：低功耗时强制开启
- (void)setPowerSaveActive:(BOOL)active {
    if (_cpuLowPowerModeActive) {
        // 低功耗模式下始终强制省电模式
        %orig(YES);
        return;
    }
    %orig;
}

// CPU 频率等级：低功耗时限制上限（70 = 降频约30%）
- (void)setCPULevel:(int)level {
    if (_cpuLowPowerModeActive && level > 0) {
        %orig(MIN(level, 70));
        return;
    }
    %orig;
}

// CPU 功率下限：低功耗时减半，降低最低功耗
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(int)source {
    if (_cpuLowPowerModeActive && floor > 0) {
        %orig(floor / 2, source);
        return;
    }
    %orig;
}

// CPU 目标功率反馈：低功耗时至少报告 50%，阻止系统认为已足够
- (int)getCPUTargetPower {
    int orig = %orig;
    if (_cpuLowPowerModeActive) {
        return MAX(orig, 50);
    }
    return orig;
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

    // 监听偏好重载通知（如 CPU 模式切换）
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        reloadPrefsCallback,
        CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
