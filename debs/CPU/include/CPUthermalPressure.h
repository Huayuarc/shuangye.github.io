#ifndef CPUTHERMAL_THERMAL_PRESSURE_H
#define CPUTHERMAL_THERMAL_PRESSURE_H

#import <Foundation/Foundation.h>
#import <notify.h>
#import <os/base.h>

// 对应 "com.apple.system.thermalpressurelevel[span_16](start_span)"[span_16](end_span)
__OSX_AVAILABLE_STARTING(__MAC_10_10, __IPHONE_7_0)
extern const char *const kOSThermalNotificationPressureLevelName;

// 强制热压力为 Nominal[span_17](start_span)[span_17](end_span)
static inline int CPUthermalForceNominalPressure(void) {
    int token = 0;
    if (notify_register_check(kOSThermalNotificationPressureLevelName, &token)) return -1;
    if (notify_set_state(token, 0)) { notify_cancel(token); return 1; }
    notify_post(kOSThermalNotificationPressureLevelName);
    notify_cancel(token);
    return 0;
}

// 强制热通知级别为 Normal[span_18](start_span)[span_18](end_span)
static inline void CPUthermalForceNormalNotifLevel(void) {
    int token = 0;
    if (notify_register_check("com.apple.system.thermalnotification", &token) == 0) {
        notify_set_state(token, 0); // Normal
        notify_post("com.apple.system.thermalnotification");
        notify_cancel(token);
    }
}

// 组合调用：同时强制压力 Nominal + 通知 Normal[span_19](start_span)[span_19](end_span)
static inline void CPUthermalForceNominalCombined(void) {
    CPUthermalForceNominalPressure();
    CPUthermalForceNormalNotifLevel();
}

#endif /* CPUTHERMAL_THERMAL_PRESSURE_H */
