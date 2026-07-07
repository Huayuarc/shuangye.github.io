//
// ThermalPatcher_reversed.m
// 逆向还原自 ThermalPatcher.dylib (com.huayuarc.thermalpatcher.rootless)
// 插件描述: 温控 — 禁用 iOS 温控降频
// 还原日期: 2026-07-07
//
// 依赖框架: Foundation, UIKit, CoreFoundation, IOKit, SpringBoardServices, CoreSymbolication
// Hook 引擎: CydiaSubstrate (mobilesubstrate)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>


#pragma mark - 类声明 (被 Hook 的系统类)

// ThermalMonitor — iOS 热监控管理器
@interface ThermalMonitor : NSObject
- (int)thermalLevel;
- (NSDictionary *)thermalMitigationData;
@end

// DVFSController — 动态电压频率调节控制器
@interface DVFSController : NSObject
+ (void)configureWithPolicy:(NSDictionary *)policy;
- (double)maxSupportedFrequency;
- (BOOL)applyThermalThrottling;
@end

// SBBrightnessController — SpringBoard 亮度控制器
@interface SBBrightnessController : NSObject
- (void)setBrightnessLevel:(float)level forReason:(NSString *)reason;
@end

// Launchd — iOS 服务进程管理器
@interface Launchd : NSObject
- (BOOL)shouldKeepRunningService:(NSString *)serviceName;
@end

// CSDevice — 凝聚态(散热)状态检测
@interface CSDevice : NSObject
- (BOOL)_isThermalStateRestricted;
- (BOOL)_shouldReducePerformance;
@end

// IOService — IOKit 服务封装
@interface IOService : NSObject
- (BOOL)isThermalMitigationEnabled;
- (int)currentThermalLevel;
@end


#pragma mark - 原始 IMP 指针

static int (*orig_ThermalMonitor_thermalLevel)(ThermalMonitor *self, SEL _cmd);
static NSDictionary *(*orig_ThermalMonitor_thermalMitigationData)(ThermalMonitor *self, SEL _cmd);
static void (*orig_DVFSController_configureWithPolicy)(id self, SEL _cmd, NSDictionary *policy);
static double (*orig_DVFSController_maxSupportedFrequency)(DVFSController *self, SEL _cmd);
static BOOL (*orig_DVFSController_applyThermalThrottling)(DVFSController *self, SEL _cmd);
static void (*orig_SBBrightnessController_setBrightnessLevel_forReason)(SBBrightnessController *self, SEL _cmd, float brightness, NSString *reason);
static BOOL (*orig_Launchd_shouldKeepRunningService)(Launchd *self, SEL _cmd, NSString *serviceName);
static BOOL (*orig_CSDevice_isThermalStateRestricted)(CSDevice *self, SEL _cmd);
static BOOL (*orig_CSDevice_shouldReducePerformance)(CSDevice *self, SEL _cmd);
static BOOL (*orig_IOService_isThermalMitigationEnabled)(IOService *self, SEL _cmd);
static int (*orig_IOService_currentThermalLevel)(IOService *self, SEL _cmd);


#pragma mark - Hook 替换函数实现

// ──────────────────────────────────────────────────
// ThermalMonitor.thermalLevel → 返回 0
// ──────────────────────────────────────────────────
static int hook_ThermalMonitor_thermalLevel(ThermalMonitor *self, SEL _cmd) {
    return 0;
}

// ──────────────────────────────────────────────────
// ThermalMonitor.thermalMitigationData
//   返回伪造的高性能策略字典
// ──────────────────────────────────────────────────
static NSDictionary *hook_ThermalMonitor_thermalMitigationData(ThermalMonitor *self, SEL _cmd) {
    return @{
        @"CPUMaxFreq":   @(3700000000.0),   // 3.70 GHz
        @"GPUMaxFreq":   @(3240000000.0),   // 3.24 GHz
        @"CPUPriority":  @(255),             // 最高 CPU 优先级
        @"IOPriority":   @(255),             // 最高 IO 优先级
        @"VoltageScale": @(1.0),             // 满电压
        @"ThermalClamp": @(0)                // 无温度钳制
    };
}

// ──────────────────────────────────────────────────
// DVFSController (类方法) configureWithPolicy:
// ──────────────────────────────────────────────────
static void hook_DVFSController_configureWithPolicy(id self, SEL _cmd, NSDictionary *policy) {
    NSDictionary *hackedPolicy = @{
        @"CPUPriority": @(3700000000.0)
    };
    orig_DVFSController_configureWithPolicy(self, _cmd, hackedPolicy);
}

// ──────────────────────────────────────────────────
// DVFSController.maxSupportedFrequency → 3.7 GHz
// ──────────────────────────────────────────────────
static double hook_DVFSController_maxSupportedFrequency(DVFSController *self, SEL _cmd) {
    return 3700000000.0;
}

// ──────────────────────────────────────────────────
// DVFSController.applyThermalThrottling → NO
// ──────────────────────────────────────────────────
static BOOL hook_DVFSController_applyThermalThrottling(DVFSController *self, SEL _cmd) {
    return NO;
}

// ──────────────────────────────────────────────────
// SBBrightnessController.setBrightnessLevel:forReason:
//   防亮度降低：检测到亮度已被调低时强制设为 1.0
// ──────────────────────────────────────────────────
static void hook_SBBrightnessController_setBrightnessLevel_forReason(
    SBBrightnessController *self, SEL _cmd, float brightness, NSString *reason) {

    float newBrightness = brightness;
    float currentBrightness = [UIScreen mainScreen].brightness;

    if (currentBrightness < 1.0) {
        newBrightness = 1.0;
    }

    orig_SBBrightnessController_setBrightnessLevel_forReason(
        self, _cmd, newBrightness, reason);
}

// ──────────────────────────────────────────────────
// Launchd.shouldKeepRunningService:
//   阻止热管理守护进程运行
// ──────────────────────────────────────────────────
static BOOL hook_Launchd_shouldKeepRunningService(Launchd *self, SEL _cmd, NSString *serviceName) {
    static NSArray *thermalServices = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        thermalServices = @[
            @"com.apple.thermal",
            @"com.apple.thermalmonitor",
            @"com.apple.throttle",
            @"com.apple.fpsmonitor",
            @"com.apple.batteryrpc",
            @"com.apple.powermanagement",
            @"com.apple.mobilethermalservice"
        ];
    });

    NSString *firstComponent = [[[serviceName componentsSeparatedByString:@"."]
        firstObject] lowercaseString];

    if ([thermalServices containsObject:firstComponent]) {
        return NO;
    }

    return orig_Launchd_shouldKeepRunningService(self, _cmd, serviceName);
}

// ──────────────────────────────────────────────────
// CSDevice/IOService 温控状态 — 全部返回 NO/0
// ──────────────────────────────────────────────────
static BOOL hook_CSDevice_isThermalStateRestricted(CSDevice *self, SEL _cmd) {
    return NO;
}

static BOOL hook_CSDevice_shouldReducePerformance(CSDevice *self, SEL _cmd) {
    return NO;
}

static BOOL hook_IOService_isThermalMitigationEnabled(IOService *self, SEL _cmd) {
    return NO;
}

static int hook_IOService_currentThermalLevel(IOService *self, SEL _cmd) {
    return 0;
}


#pragma mark - 构造器

__attribute__((constructor))
static void init() {
    // ThermalMonitor
    MSHookMessageEx(
        objc_getClass("ThermalMonitor"),
        @selector(thermalLevel),
        (IMP)&hook_ThermalMonitor_thermalLevel,
        (IMP *)&orig_ThermalMonitor_thermalLevel
    );

    MSHookMessageEx(
        objc_getClass("ThermalMonitor"),
        @selector(thermalMitigationData),
        (IMP)&hook_ThermalMonitor_thermalMitigationData,
        (IMP *)&orig_ThermalMonitor_thermalMitigationData
    );

    // DVFSController
    MSHookMessageEx(
        object_getClass(objc_getClass("DVFSController")),
        @selector(configureWithPolicy:),
        (IMP)&hook_DVFSController_configureWithPolicy,
        (IMP *)&orig_DVFSController_configureWithPolicy
    );

    MSHookMessageEx(
        objc_getClass("DVFSController"),
        @selector(maxSupportedFrequency),
        (IMP)&hook_DVFSController_maxSupportedFrequency,
        (IMP *)&orig_DVFSController_maxSupportedFrequency
    );

    MSHookMessageEx(
        objc_getClass("DVFSController"),
        @selector(applyThermalThrottling),
        (IMP)&hook_DVFSController_applyThermalThrottling,
        (IMP *)&orig_DVFSController_applyThermalThrottling
    );

    // SBBrightnessController
    MSHookMessageEx(
        objc_getClass("SBBrightnessController"),
        @selector(setBrightnessLevel:forReason:),
        (IMP)&hook_SBBrightnessController_setBrightnessLevel_forReason,
        (IMP *)&orig_SBBrightnessController_setBrightnessLevel_forReason
    );

    // Launchd
    MSHookMessageEx(
        objc_getClass("Launchd"),
        @selector(shouldKeepRunningService:),
        (IMP)&hook_Launchd_shouldKeepRunningService,
        (IMP *)&orig_Launchd_shouldKeepRunningService
    );

    // CSDevice
    MSHookMessageEx(
        objc_getClass("CSDevice"),
        @selector(_isThermalStateRestricted),
        (IMP)&hook_CSDevice_isThermalStateRestricted,
        (IMP *)&orig_CSDevice_isThermalStateRestricted
    );

    MSHookMessageEx(
        objc_getClass("CSDevice"),
        @selector(_shouldReducePerformance),
        (IMP)&hook_CSDevice_shouldReducePerformance,
        (IMP *)&orig_CSDevice_shouldReducePerformance
    );

    // IOService
    MSHookMessageEx(
        objc_getClass("IOService"),
        @selector(isThermalMitigationEnabled),
        (IMP)&hook_IOService_isThermalMitigationEnabled,
        (IMP *)&orig_IOService_isThermalMitigationEnabled
    );

    MSHookMessageEx(
        objc_getClass("IOService"),
        @selector(currentThermalLevel),
        (IMP)&hook_IOService_currentThermalLevel,
        (IMP *)&orig_IOService_currentThermalLevel
    );
}
