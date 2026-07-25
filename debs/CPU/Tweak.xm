#import "CPUthermalHelper.h"

// ============================================================
// 根据当前偏好设置 thermalmonitord 的工作模式
// ============================================================
static void CPUthermalApplyMode(void) {
    CPUthermalHelper *helper = CPUthermalHelper.shared;
    [helper reloadPrefs];

    if (!helper.commonProductObject) return;

    if (helper.thermalFullPowerEnabled) {
        // 防止温控降频：强制标称模式，阻止一切温控动作
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"nominal"];
    } else if (helper.thermalLowPowerEnabled) {
        // 模拟低电频率：模拟中度热压力，触发系统降频
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"moderate"];
    } else {
        // 关闭：还原原生温控
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"nominal"];
    }
}

// ============================================================
// CommonProduct - 条件性温控管理
// ============================================================
%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
    CPUthermalApplyMode();
    return res;
}

- (void)tryTakeAction {
    if ([CPUthermalHelper.shared thermalFullPowerEnabled]) {
        // 全性能：阻止一切温控缓解动作
        return;
    }
    // 低电模式 / 关闭：允许原生温控动作
    %orig;
}

- (void)simulateLightThermalPressure {
    if ([CPUthermalHelper.shared thermalFullPowerEnabled]) {
        return; // 全性能：阻止轻度热压力模拟
    }
    %orig;
}

- (void)updatePowerzoneTelemetry {
    if ([CPUthermalHelper.shared thermalFullPowerEnabled]) {
        return; // 全性能：阻止功率区域遥测更新
    }
    %orig;
}

%end

// ============================================================
// HidSensors - 条件性温度事件处理
// ============================================================
%hook HidSensors

- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2 {
    if ([CPUthermalHelper.shared thermalFullPowerEnabled]) {
        return; // 全性能：阻止温度事件触发缓解逻辑
    }
    %orig(arg1, arg2); // 低电模式/关闭：允许原生温度处理
}

%end

// ============================================================
// NSDictionary - 修补温控配置文件
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

    // 监听偏好重载通知（如防温控暗屏、模拟低电、防止降频等开关变更）
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        reloadPrefsCallback,
        CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
