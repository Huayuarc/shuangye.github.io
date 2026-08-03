#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <limits.h>
#import <stdint.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <mach/host_info.h>
#import <mach/task_info.h>

#include <CPUthermalPaths.h>
#import <CPUthermalPressure.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/pwr_mgt/IOPM.h>

// ============================================================================
// MARK: - ObjC 类声明 (对齐 insulation 原生私有类头)
// ============================================================================
@interface CommonProduct : NSObject
- (id)initProduct:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)tryTakeAction;
- (void)simulateLightThermalPressure;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)setCPULevel:(int)level;
- (void)setThermalState:(id)state;
@end

@interface ThermalManager : NSObject
- (void)evaluateDecisionTree;
- (void)updateThermalNotification:(id)notification;
- (float)getReleaseRateForComponent:(id)component;
@end

@interface ThermalControl : NSObject
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2;
- (void)actionComponentControl;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

@interface MitigationController : NSObject
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (void)setCPULevel:(int)level;
- (void)updateCPU;
- (void)updateGPU;
- (void)updatePackage;
- (void)setCPULowPowerTarget:(int)target;
- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerZoneTarget:(int)target;
- (void)setPackagePowerBudgetDirect:(int)budget details:(id)details;
@end

@interface HidSensors : NSObject
- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2;
@end

// ============================================================================
// MARK: - 全局配置与状态变量
// ============================================================================
typedef enum {
    CPUthermalPowerModeFull = 0,
    CPUthermalPowerModeLow  = 1
} CPUthermalPowerMode;

static BOOL g_enabled                      = YES;
static BOOL g_cpuProtection                = YES;
static BOOL g_thermalBlockNotifPopup        = YES;
static BOOL g_thermalPreventDimmingEnabled = YES;

static CPUthermalPowerMode g_powerMode     = CPUthermalPowerModeFull;

// 65W 解封上限 (mW) & 100°C 硬件安全阈值
static const int kUnrestrictedPowerLimitMW  = 65000;
static const int64_t kSafetyTempThreshold   = 100000;

// 弱引用实例容器 (避免内存泄漏/野指针)
static CommonProduct *g_commonProduct       = nil;
static NSHashTable *g_mitigationControllers  = nil;
static NSHashTable *g_applePPMInstances      = nil;
static os_unfair_lock g_modeLock            = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_connLock            = OS_UNFAIR_LOCK_INIT;

static BOOL g_restoringFullPower            = NO;
static BOOL g_applyingLowPower              = NO;

// 保活定时器
static dispatch_source_t g_keepAliveTimer   = NULL;
static const double kKeepAliveInterval      = 1.0;

// ============================================================================
// MARK: - 模式与辅助判断
// ============================================================================
static BOOL isLowPowerMode(void) {
    os_unfair_lock_lock(&g_modeLock);
    BOOL res = (g_powerMode == CPUthermalPowerModeLow);
    os_unfair_lock_unlock(&g_modeLock);
    return res;
}

static BOOL isFullPowerMode(void) {
    os_unfair_lock_lock(&g_modeLock);
    BOOL res = (g_powerMode == CPUthermalPowerModeFull);
    os_unfair_lock_unlock(&g_modeLock);
    return res;
}

static BOOL shouldApplyFullCPUProtection(void) {
    return g_enabled && g_cpuProtection && isFullPowerMode();
}

static BOOL shouldApplyLowPowerLimit(void) {
    return g_enabled && g_cpuProtection && isLowPowerMode();
}

static void trackPowerController(id controller) {
    if (!controller) return;
    if (!g_mitigationControllers) g_mitigationControllers = [NSHashTable weakObjectsHashTable];
    [g_mitigationControllers addObject:controller];
}

// ============================================================================
// MARK: - 状态下发与定时保活 (参照 insulation IPowerHelper 实现)
// ============================================================================
static void applyLowPowerToControllers(void) {
    if (!shouldApplyLowPowerLimit()) return;
    g_applyingLowPower = YES;
    @autoreleasepool {
        if (g_commonProduct) {
            if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) [g_commonProduct setCPMSMitigationsEnabled:YES];
            if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) [g_commonProduct setCPULevel:2];
        }
        for (id controller in [g_mitigationControllers allObjects]) {
            if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) [controller setPowerSaveActive:YES];
            if ([controller respondsToSelector:@selector(setCPULevel:)]) [controller setCPULevel:2]; // 低功耗 P-State Level 2
            if ([controller respondsToSelector:@selector(updateCPU)]) [controller updateCPU];
        }
        for (id ppm in [g_applePPMInstances allObjects]) {
            if ([ppm respondsToSelector:@selector(setCPULevel:)]) [ppm setCPULevel:2];
            if ([ppm respondsToSelector:@selector(updateCPU)]) [ppm updateCPU];
        }
    }
    g_applyingLowPower = NO;
}

static void restoreFullPowerToControllers(void) {
    if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
    g_restoringFullPower = YES;
    @autoreleasepool {
        if (g_commonProduct) {
            if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) [g_commonProduct setCPMSMitigationsEnabled:NO]; // 彻底关闭 CPMS 抑制
            if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) [g_commonProduct setCPULevel:0];
        }
        for (id controller in [g_mitigationControllers allObjects]) {
            if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) [controller setPowerSaveActive:NO];
            if ([controller respondsToSelector:@selector(setCPULevel:)]) [controller setCPULevel:0];
            if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
                [controller setCPUPowerCeiling:kUnrestrictedPowerLimitMW fromDecisionSource:0];
            }
            if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)]) {
                [controller setCPUPowerFloor:kUnrestrictedPowerLimitMW fromDecisionSource:0];
            }
            if ([controller respondsToSelector:@selector(setPackagePowerBudgetDirect:details:)]) {
                [controller setPackagePowerBudgetDirect:kUnrestrictedPowerLimitMW details:nil];
            }
            if ([controller respondsToSelector:@selector(updateCPU)]) [controller updateCPU];
        }
    }
    CPUthermalForceNominalCombined();
    g_restoringFullPower = NO;
}

static void startKeepAliveTimer(void) {
    if (g_keepAliveTimer) {
        dispatch_source_cancel(g_keepAliveTimer);
        g_keepAliveTimer = NULL;
    }

    dispatch_queue_t queue = dispatch_get_main_queue();
    g_keepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(g_keepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0), kKeepAliveInterval * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(g_keepAliveTimer, ^{
        if (isLowPowerMode() && shouldApplyLowPowerLimit()) {
            CPUthermalForceNominalCombined();
            applyLowPowerToControllers();
        } else if (isFullPowerMode() && shouldApplyFullCPUProtection()) {
            restoreFullPowerToControllers();
        }
    });
    dispatch_resume(g_keepAliveTimer);
}

static void applyCurrentPowerModeToRuntime(void) {
    if (isLowPowerMode()) {
        applyLowPowerToControllers();
    } else {
        restoreFullPowerToControllers();
    }
    startKeepAliveTimer();
}

static void loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = CPUthermalReadPrefs();
        if (!d) return;
        g_enabled                      = YES;
        g_cpuProtection                = YES;
        g_thermalBlockNotifPopup        = [d[S("thermalBlockNotifPopup")] ?: @YES boolValue];
        g_thermalPreventDimmingEnabled = [d[S("thermalPreventDimmingEnabled")] ?: @YES boolValue];

        NSString *mode = d[S("powerMode")] ?: S("fullPower");
        os_unfair_lock_lock(&g_modeLock);
        g_powerMode = [mode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;
        os_unfair_lock_unlock(&g_modeLock);
    }
}

// ============================================================================
// MARK: - IOKit Connection 追踪与 CallMethod 拦截
// ============================================================================
#define MAX_CONN 64
typedef struct { io_connect_t conn; BOOL isThermal; } ConnEntry;
static ConnEntry g_conns[MAX_CONN];
static int g_connCount = 0;

static void trackConnection(io_connect_t conn, BOOL thermal) {
    os_unfair_lock_lock(&g_connLock);
    if (g_connCount < MAX_CONN) {
        g_conns[g_connCount].conn = conn;
        g_conns[g_connCount].isThermal = thermal;
        g_connCount++;
    }
    os_unfair_lock_unlock(&g_connLock);
}

static BOOL isThermalConnection(io_connect_t conn) {
    os_unfair_lock_lock(&g_connLock);
    BOOL res = NO;
    for (int i = 0; i < g_connCount; i++) {
        if (g_conns[i].conn == conn) { res = g_conns[i].isThermal; break; }
    }
    os_unfair_lock_unlock(&g_connLock);
    return res;
}

static BOOL isTemperatureAboveSafetyCeiling(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("AppleARMPlatform");
    if (!matching) return NO;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
    if (!service) return NO;
    CFTypeRef temp = IORegistryEntryCreateCFProperty(service, CFSTR("temperature"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (!temp) return NO;
    int64_t tempVal = 0;
    BOOL isOver = CFNumberGetValue((CFNumberRef)temp, kCFNumberSInt64Type, &tempVal) && (tempVal >= kSafetyTempThreshold);
    CFRelease(temp);
    return isOver;
}

#define SELECTOR_IS_MITIGATION(s) ((s) >= 0x20 && (s) <= 0x5F)

%hookf(kern_return_t, IOServiceOpen, io_service_t service, task_t task, uint32_t type, io_connect_t *connect) {
    kern_return_t ret = %orig;
    if (ret == KERN_SUCCESS) {
        io_name_t name;
        BOOL isThermal = (IORegistryEntryGetName(service, name) == KERN_SUCCESS && 
                         (strstr(name, "AppleARMPlatform") || strstr(name, "pmu") || strstr(name, "ApplePMGR")));
        trackConnection(*connect, isThermal);
    }
    return ret;
}

%hookf(kern_return_t, IOServiceClose, io_connect_t connect) {
    os_unfair_lock_lock(&g_connLock);
    for (int i = 0; i < g_connCount; i++) {
        if (g_conns[i].conn == connect) {
            g_conns[i] = g_conns[--g_connCount];
            break;
        }
    }
    os_unfair_lock_unlock(&g_connLock);
    return %orig(connect);
}

// 拦截底层同步、异步与结构体 CallMethod
%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
    if (g_enabled && isThermalConnection(connection) && !g_restoringFullPower && !isTemperatureAboveSafetyCeiling()) {
        if ((shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) && SELECTOR_IS_MITIGATION(selector)) {
            return KERN_SUCCESS;
        }
    }
    return %orig;
}

%hookf(kern_return_t, IOConnectCallAsyncMethod, mach_port_t connection, uint32_t selector, mach_port_t wakePort, mach_port_t *asyncRef, uint32_t asyncRefCnt, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
    if (g_enabled && isThermalConnection(connection) && !g_restoringFullPower && !isTemperatureAboveSafetyCeiling()) {
        if ((shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) && SELECTOR_IS_MITIGATION(selector)) {
            return KERN_SUCCESS;
        }
    }
    return %orig;
}

%hookf(kern_return_t, IOConnectCallStructMethod, mach_port_t connection, uint32_t selector, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
    if (g_enabled && isThermalConnection(connection) && !g_restoringFullPower && !isTemperatureAboveSafetyCeiling()) {
        if ((shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) && SELECTOR_IS_MITIGATION(selector)) {
            return KERN_SUCCESS;
        }
    }
    return %orig;
}

static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;
static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (g_enabled && g_cpuProtection && !isTemperatureAboveSafetyCeiling()) {
        NSString *ks = [(__bridge NSString *)key lowercaseString];
        if ([ks containsString:@"cpu"] || [ks containsString:@"freq"] || [ks containsString:@"throttle"]) {
            if (isFullPowerMode()) return KERN_SUCCESS;
        }
    }
    return orig_IOServiceSetProperty(service, key, value);
}

// ============================================================================
// MARK: - ObjC 类 Hooks (对齐 insulation 核心控制)
// ============================================================================
%hook CommonProduct
- (id)initProduct:(id)arg1 {
    id res = %orig;
    g_commonProduct = self;
    [self putDeviceInThermalSimulationMode:S("nominal")];
    applyCurrentPowerModeToRuntime();
    return res;
}

- (void)tryTakeAction {
    if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
        CPUthermalForceNominalCombined();
        return;
    }
    %orig;
}

- (void)simulateLightThermalPressure {
    if (shouldApplyFullCPUProtection()) return; // 满血禁用轻度热压力
    %orig;
}

- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
    if (shouldApplyFullCPUProtection()) { %orig(NO); return; } // CPMS 强行关闭
    if (shouldApplyLowPowerLimit()) { %orig(YES); return; }
    %orig(enabled);
}

- (void)setCPULevel:(int)level {
    if (g_restoringFullPower) { %orig(level); return; }
    if (shouldApplyLowPowerLimit()) { %orig(2); return; }
    if (shouldApplyFullCPUProtection()) { %orig(0); return; }
    %orig(level);
}
%end

%hook ThermalManager
- (void)evaluateDecisionTree {
    if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
        CPUthermalForceNominalCombined();
        return; // 切断降频决策树
    }
    %orig;
}

- (void)updateThermalNotification:(id)notification {
    if (g_thermalBlockNotifPopup) return; // 屏蔽高温弹窗
    %orig;
}

- (float)getReleaseRateForComponent:(id)component {
    if (shouldApplyFullCPUProtection()) return 0.0f;
    return %orig(component);
}
%end

%hook ThermalControl
- (id)initForFastLoop:(BOOL)f noDisplay:(BOOL)n powerSaveParams:(id)p1 powerZoneParams:(id)p2 {
    id res = %orig(f, n, p1, p2);
    trackPowerController(res);
    return res;
}

- (void)setPowerSaveActive:(BOOL)active {
    trackPowerController(self);
    if (shouldApplyLowPowerLimit()) { %orig(YES); return; }
    if (shouldApplyFullCPUProtection()) { %orig(NO); return; }
    %orig(active);
}

- (float)calculateControlEffort:(id)t1 trigger:(id)t2 {
    if (shouldApplyFullCPUProtection()) return 0.0f;
    return %orig(t1, t2);
}

- (void)actionComponentControl {
    if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) return;
    %orig;
}
%end

%hook ApplePPMCPU
- (id)init {
    id res = %orig;
    if (res) {
        if (!g_applePPMInstances) g_applePPMInstances = [NSHashTable weakObjectsHashTable];
        [g_applePPMInstances addObject:res];
    }
    return res;
}

- (void)setCPULevel:(int)level {
    if (self && !g_applePPMInstances) g_applePPMInstances = [NSHashTable weakObjectsHashTable];
    if (self) [g_applePPMInstances addObject:self];
    if (shouldApplyLowPowerLimit()) { %orig(2); return; }
    if (shouldApplyFullCPUProtection()) { %orig(0); return; }
    %orig(level);
}
%end

%hook MitigationController
- (id)initForFastLoop:(BOOL)f noDisplay:(BOOL)n powerSaveParams:(id)p1 powerZoneParams:(id)p2 {
    id res = %orig(f, n, p1, p2);
    trackPowerController(res);
    return res;
}

- (void)setCPULevel:(int)level {
    if (shouldApplyLowPowerLimit()) { %orig(2); return; }
    if (shouldApplyFullCPUProtection()) { %orig(0); return; }
    %orig(level);
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
    if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW, source); return; }
    %orig(ceiling, source);
}

- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
    if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW, source); return; }
    %orig(floor, source);
}

- (void)setPackagePowerBudgetDirect:(int)budget details:(id)details {
    if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW, details); return; }
    %orig(budget, details);
}
%end

%hook HidSensors
- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2 {
    if (g_enabled && g_thermalBlockNotifPopup) return;
    %orig;
}
%end

// ============================================================================
// MARK: - IORegistry 伪装层 (汇报 30°C 与 Nominal 热等级防反弹)
// ============================================================================
static CFPropertyListRef (*orig_IORegistryEntryCreateCFProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static CFPropertyListRef fake_IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    CFTypeRef result = orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    if (result && shouldApplyFullCPUProtection()) {
        if (key && CFGetTypeID(key) == CFStringGetTypeID()) {
            NSString *nsKey = (__bridge NSString *)key;
            if ([nsKey isEqualToString:@"Temperature"] || [nsKey isEqualToString:@"BatteryTemperature"]) {
                CFRelease(result);
                return (__bridge_retained CFPropertyListRef)@30; // 伪装为 30°C
            }
            if ([nsKey isEqualToString:@"ThermalLevel"]) {
                CFRelease(result);
                return (__bridge_retained CFPropertyListRef)@0; // 伪装为 Nominal
            }
        }
    }
    return result;
}

// ============================================================================
// MARK: - 构造函数 (%ctor)
// ============================================================================
%ctor {
    @autoreleasepool {
        loadPrefs();

        // 绑定 IOKit 基础 Hook
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (iokit) {
            void *ptr = dlsym(iokit, "IOServiceSetProperty");
            if (ptr) MSHookFunction(ptr, (void *)hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
        }

        // 绑定 IORegistry 防反弹 Hook
        void *libSystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOLOAD);
        if (libSystem) {
            void *symIOReg = dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
            if (symIOReg) MSHookFunction(symIOReg, (void *)fake_IORegistryEntryCreateCFProperty, (void **)&orig_IORegistryEntryCreateCFProperty);
        }

        CPUthermalForceNominalCombined();

        // 注册设置重载 Darwin 通知
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            CFNotificationCenterAddObserver(c, NULL, (CFNotificationCallback)loadPrefs,
                (__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(c, NULL, (CFNotificationCallback)applyCurrentPowerModeToRuntime,
                (__bridge CFStringRef)S(kCPUthermalPowerModeChangedNotifC), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        applyCurrentPowerModeToRuntime();
    }
}
