#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import "CPUthermalThermalPrefs.h"
#import "CPUthermalHelper.h"

// MitigationController 需要挂钩的方法原型声明
typedef void (*SetPowerSaveActiveType)(id self, SEL _cmd, BOOL active);
typedef void (*SetCPULevelType)(id self, SEL _cmd, int level);
typedef void (*SetCPUPowerFloorType)(id self, SEL _cmd, int floor, id source);

// 保存原始系统函数地址
static SetPowerSaveActiveType orig_setPowerSaveActive = NULL;
static SetCPULevelType orig_setCPULevel = NULL;
static SetCPUPowerFloorType orig_setCPUPowerFloor = NULL;

// 【可调参数】低功耗最大温控限制档位，范围建议65~80，越大性能越强
static const int kLowPowerMaxCPULevel = 65;

// 串行队列：保护模式读取，防止多线程冲突
static dispatch_queue_t g_modeQueue;

/**
 * 读取当前选中模式
 * return 1 = 低功耗 ｜ 2 = 解除温控
 */
static NSInteger GetCurrentThermalMode(void) {
    __block NSInteger mode;
    dispatch_sync(g_modeQueue, ^{
        mode = [CPUthermalHelper.shared loadThermalMode];
    });
    return mode;
}

// Hook：系统调用 setPowerSaveActive（是否开启省电缓解）
static void hook_setPowerSaveActive(id self, SEL _cmd, BOOL active) {
    NSInteger mode = GetCurrentThermalMode();
    
    if (mode == 1) {
        // 低功耗：强制永久开启省电策略，主动限制性能
        orig_setPowerSaveActive(self, _cmd, YES);
        return;
    }
    if (mode == 2 && active) {
        // 解除温控：拦截系统发起省电降频指令
        return;
    }
    orig_setPowerSaveActive(self, _cmd, active);
}

// Hook：系统设置CPU温控等级
static void hook_setCPULevel(id self, SEL _cmd, int level) {
    NSInteger mode = GetCurrentThermalMode();
    
    if (mode == 1) {
        // 低功耗：限制最高档位，禁止系统拉高性能
        if (level > kLowPowerMaxCPULevel) {
            orig_setCPULevel(self, _cmd, kLowPowerMaxCPULevel);
            return;
        }
    }
    if (mode == 2) {
        // 解除温控：强制等级0 = 无温控限制
        orig_setCPULevel(self, _cmd, 0);
        return;
    }
    orig_setCPULevel(self, _cmd, level);
}

// Hook：设置功耗下限
static void hook_setCPUPowerFloor(id self, SEL _cmd, int floor, id source) {
    NSInteger mode = GetCurrentThermalMode();
    
    if (mode == 1) {
        // 低功耗：下压最低功耗基线，进一步降低待机/负载功耗
        orig_setCPUPowerFloor(self, _cmd, floor / 2, source);
        return;
    }
    orig_setCPUPowerFloor(self, _cmd, floor, source);
}

/**
 * 通用Hook挂载工具函数
 */
static IMP HookMethod(Class cls, SEL sel, IMP replace, IMP *origin) {
    if (!cls) return nil;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) m = class_getClassMethod(cls, sel);
    if (!m) return nil;
    IMP imp = method_getImplementation(m);
    method_setImplementation(m, replace);
    if (origin) *origin = imp;
    return imp;
}

// 偏好变更通知回调，仅打印日志，模式读取自动生效
static void PrefsReloadCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    @autoreleasepool {
        NSLog(@"[CPUthermal-Mode] 温控模式已切换");
    }
}

// 模块构造函数，仅在thermalmonitord进程执行Hook
__attribute__((constructor)) static void LowPowerMitigationInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        // 关键：只在温控守护进程执行，避免其他进程异常Hook崩溃
        if (![proc isEqualToString:@"thermalmonitord"]) return;

        g_modeQueue = dispatch_queue_create("com.huayuarc.cputhermal.modequeue", DISPATCH_QUEUE_SERIAL);
        Class MitigationController = objc_getClass("MitigationController");
        
        if (MitigationController) {
            HookMethod(MitigationController, @selector(setPowerSaveActive:),
                       (IMP)hook_setPowerSaveActive, (IMP *)&orig_setPowerSaveActive);

            HookMethod(MitigationController, @selector(setCPULevel:),
                       (IMP)hook_setCPULevel, (IMP *)&orig_setCPULevel);

            HookMethod(MitigationController, @selector(setCPUPowerFloor:fromDecisionSource:),
                       (IMP)hook_setCPUPowerFloor, (IMP *)&orig_setCPUPowerFloor);
        }

        // 监听全局偏好刷新通知，与主程序保持统一
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(nc, NULL, PrefsReloadCallback,
                                        CFSTR("com.huayuarc.cputhermal.reloadPrefs"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}