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
// MARK: - ObjC 类声明 (对齐 CPU(1) 完全版类头 + insulation 原生私有类头)
// ============================================================================

// CommonProduct — thermalmonitord 核心热管理对象
@interface CommonProduct : NSObject
- (id)initProduct:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)tryTakeAction;
- (void)simulateLightThermalPressure;
- (void)updatePowerzoneTelemetry;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)setCPULevel:(int)level;
- (void)setThermalState:(id)state;
@end

// HidSensors — HID 温度事件处理
@interface HidSensors : NSObject
+ (id)sharedInstance;
- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2;
@end

// ThermalManager — 决策树 / 热压力管理
@interface ThermalManager : NSObject
- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table;
- (void)evaluateDecisionTree;
- (id)findComponent:(id)component;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
- (float)getReleaseRateForComponent:(id)component;
- (int)getPotentialForcedThermalLevel:(id)component;
- (int)getPotentialForcedThermalPressureLevel;
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force;
- (void)updateThermalNotification:(id)notification;
- (BOOL)shouldEnforceLightThermalPressure;
- (void)setCPMSMitigationState:(int)state;
- (id)getBatteryServiceSuggestion:(id)suggestion;
@end

// ThermalControl — 控制力度 / 功率计算
@interface ThermalControl : NSObject
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (id)initWithParams:(id)params;
- (void)updatePowerParameters:(id)params;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (BOOL)powerSaveActive;
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2;
- (id)findCC:(id)component;
- (float)dieTempFilteredMaxAverage;
- (float)getHighestSkinTemp;
- (float)thermalSensorValuesMaxFromIndexSet:(id)indexSet;
- (void)copyDieTempSensorIndexSetForFourthChar:(char)c sensors:(id)sensors;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
@end

// ThermalDecisionTable — 决策表
@interface ThermalDecisionTable : NSObject
- (id)initDecisionTable:(id)table;
@end

// PIDController — PID 控制器
@interface PIDController : NSObject
- (id)initPIDWith:(id)params;
@end

// HotspotController — 热点控制器
@interface HotspotController : NSObject
- (id)initWithParams:(id)params aggdController:(id)aggd;
@end

// CommonAggdController — 聚合控制器
@interface CommonAggdController : NSObject
- (id)initWithParams:(id)params product:(id)product;
@end

// ApplePPMCPU — CPU 电源管理
@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

// MitigationController — 缓解控制器 (核心决策执行器)
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
- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setPackagePowerBudgetDirect:(int)budget details:(id)details;
- (int)getCPUTargetPower;
- (int)getGPUTargetPower;
- (void)updateCPU;
@end

// ============================================================================
// MARK: - insulation C 函数原型 (完整逆向知识文档)
// ============================================================================
// 以下原型来自 insulation_reconstructed 对 thermalmonitord 的逆向还原，
// 完整保留作为文档。其对应功能全部已通过上方 %hook 类声明 + 下方 Logos
// hook 实现 (方法签名以 class-dump 为准，与 C 函数指针原始声明略有差异，
// 如 fromDecisionSource 参数在 class-dump 中为 uintptr_t)。
// 注意: insulation 的 method_setImplementation 方式与 Logos %hook 冲突，
// 且 reconstruction 存在已知类型错误 (notify_set_state(state,0) 传 NSDictionary、
// hook_updateCPU 内 orig_setCPULevel 传 selector 当 int)，故不移植其 hook 机制本身。
/*
typedef void (*CommonProductInitProductType)(id, SEL, id);
typedef id   (*CommonProductGetConfigurationForType)(id, SEL, id);
typedef void (*SetPowerSaveActiveType)(id, SEL, BOOL);
typedef void (*SetCPULevelType)(id, SEL, int);
typedef void (*SetCPULowPowerTargetType)(id, SEL, int);
typedef void (*SetCPUPowerCeilingType)(id, SEL, int, id);
typedef void (*SetCPUPowerCeilingForDVD1Type)(id, SEL, int);
typedef void (*SetCPUPowerFloorType)(id, SEL, int, id);
typedef void (*SetCPUPowerZoneTargetType)(id, SEL, int);
typedef void (*SetDVD1LevelType)(id, SEL, int);
typedef void (*SetGPUPowerCeilingType)(id, SEL, int, id);
typedef void (*SetGPUPowerFloorType)(id, SEL, int, id);
typedef void (*SetGPUPowerZoneTargetType)(id, SEL, int);
typedef void (*SetSGXLevelType)(id, SEL, int);
typedef void (*SetMaxGraphicsDrivePowerTargetType)(id, SEL, int);
typedef void (*SetMaxCPUPowerTargetType)(id, SEL, int, BOOL, id);
typedef void (*SetPackagePowerBudgetDirectType)(id, SEL, int, id);
typedef void (*SetPackagePowerCeilingType)(id, SEL, int, id);
typedef void (*SetPackagePowerFloorType)(id, SEL, int, id);
typedef void (*SetMaxPackagePowerType)(id, SEL, int);
typedef void (*SetPackageLowPowerTargetType)(id, SEL);
typedef void (*SetPackagePowerZoneTargetType)(id, SEL);
typedef id   (*InitForFastLoopType)(id, SEL, BOOL, BOOL, id, id);
typedef void (*UpdateCPUType)(id, SEL);
typedef void (*UpdateGPUType)(id, SEL);
typedef void (*UpdatePackageType)(id, SEL);
typedef int  (*GetCPUTargetPowerType)(id, SEL);
typedef int  (*GetGPUTargetPowerType)(id, SEL);
typedef int  (*GetPackageCPUPowerTargetType)(id, SEL);
typedef int  (*GetPackageGPUPowerTargetType)(id, SEL);
typedef int  (*GetPotentialForcedThermalLevelType)(id, SEL, int *);
typedef int  (*HandleMCSThermalPressureType)(id, SEL);
typedef id   (*GetThermalSuggestionType)(id, SEL);
typedef void (*SimulateLightThermalPressureType)(id, SEL);
typedef void (*SetThermalStateType)(id, SEL, int);
typedef void (*EngageBehaviorType)(id, SEL, BOOL);
typedef void (*EngageBehaviorPersistentlyType)(id, SEL, BOOL);
*/

// ============================================================================
// MARK: - 全局配置与状态变量
// ============================================================================
typedef enum {
    CPUthermalPowerModeOff  = 0,
    CPUthermalPowerModeFull = 1,
    CPUthermalPowerModeLow  = 2
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

static BOOL isOffMode(void) {
    os_unfair_lock_lock(&g_modeLock);
    BOOL res = (g_powerMode == CPUthermalPowerModeOff);
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
// MARK: - SC 偏好热压力深度控制 + Probe 诊断 (移植自 insulation)
// ============================================================================

// Probe 诊断路径 — 记录插件各阶段加载时间戳 (rootless/roothide 兼容)
static const char *kCPUthermalProbePathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal-probe.plist";

// 对齐 insulation InsulationProbeMarkLoaded — 每次调用记录一个 stage 时间戳
static void CPUthermalProbeMarkLoaded(NSString *stage) {
    @autoreleasepool {
        NSMutableDictionary *probe = [NSMutableDictionary dictionary];
        probe[S("version")] = S("1.6.0-probe");
        probe[stage] = @{ S("time"): [NSDate date] };
        NSString *path = CPUthermalJBRootPathForRootFSPath(kCPUthermalProbePathC);
        if (path) [probe writeToFile:path atomically:YES];
    }
}

// SCPreferences 相关 API 在 iOS SDK 头文件被标记为 unavailable (macOS Only)，
// 但符号在 iOS 运行时真实存在 (SystemConfiguration.tbd 导出)。手动声明原型
// 绕过 SDK 可用性检查，直接链接 SystemConfiguration 框架。
typedef struct __SCPreferences *CPUthermalSCPreferencesRef;
extern CPUthermalSCPreferencesRef SCPreferencesCreate(CFAllocatorRef allocator, CFStringRef name, CFStringRef prefsID);
extern Boolean SCPreferencesSetValue(CPUthermalSCPreferencesRef prefs, CFStringRef key, CFPropertyListRef value);
extern Boolean SCPreferencesRemoveValue(CPUthermalSCPreferencesRef prefs, CFStringRef key);
extern Boolean SCPreferencesCommitChanges(CPUthermalSCPreferencesRef prefs);
extern Boolean SCPreferencesApplyChanges(CPUthermalSCPreferencesRef prefs);

// SC 偏好写入 — 对齐 insulation InsulationSetSCPref
// 通过 SystemConfiguration 主偏好文件 (prefsID=NULL) 读写热压力等级
static void CPUthermalSetSCPref(NSString *key, id value) {
    if (!key || !value) return;
    CPUthermalSCPreferencesRef prefs = SCPreferencesCreate(NULL, (__bridge CFStringRef)S("CPUthermal"), NULL);
    if (!prefs) return;
    SCPreferencesSetValue(prefs, (__bridge CFStringRef)key, (__bridge CFPropertyListRef)value);
    SCPreferencesCommitChanges(prefs);
    SCPreferencesApplyChanges(prefs);
    CFRelease(prefs);
}

// SC 偏好删除 — 对齐 insulation InsulationRemoveSCPref
static void CPUthermalRemoveSCPref(NSString *key) {
    if (!key) return;
    CPUthermalSCPreferencesRef prefs = SCPreferencesCreate(NULL, (__bridge CFStringRef)S("CPUthermal"), NULL);
    if (!prefs) return;
    SCPreferencesRemoveValue(prefs, (__bridge CFStringRef)key);
    SCPreferencesCommitChanges(prefs);
    SCPreferencesApplyChanges(prefs);
    CFRelease(prefs);
}

// Darwin 热压力深度控制 — 对齐 insulation insulationSetDarwinThermalPressure
// level > 0 : 强制写入指定热压力等级覆盖
// level <= 0: 删除覆盖，恢复系统原生热压力判断
// 使用运行时符号 kOSThermalNotificationPressureLevelName (libSystem 导出，
// 即 "com.apple.system.thermalpressurelevel" Darwin 通知名，SDK 无头文件定义)
static void CPUthermalSetThermalPressureLevel(int level) {
    NSString *key = S(kOSThermalNotificationPressureLevelName);
    if (level > 0) {
        CPUthermalSetSCPref(key, @(level));
    } else {
        CPUthermalRemoveSCPref(key);
    }
}

// 恢复原生热压力行为 — 对齐 insulation insulationSetThermalMitigationsEnabled(YES)
// 所有模式下清除 SC 热压力覆盖，由 thermalmonitord/thermalpressured 自行决策
// 复用 CPUthermalSetThermalPressureLevel(0) 删除覆盖 (对齐 insulationSetDarwinThermalPressure(0))
static void CPUthermalRestoreNativeThermalPressure(void) {
    CPUthermalSetThermalPressureLevel(0);
}

// ============================================================================
// MARK: - 优化后的状态下发与平滑切换 logic
// ============================================================================

// A15 芯片 P-State 档位：Level 4/5 对应 1380MHz~1428MHz 压制
static const int kLowPowerCPULevel = 4;

static void applyLowPowerToControllers(void) {
    if (!shouldApplyLowPowerLimit()) return;
    g_applyingLowPower = YES;
    @autoreleasepool {
        if (g_commonProduct) {
            if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)])
                [g_commonProduct setCPMSMitigationsEnabled:YES];
            if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)])
                [g_commonProduct setCPULevel:kLowPowerCPULevel];
        }
        for (id controller in [g_mitigationControllers allObjects]) {
            if ([controller respondsToSelector:@selector(setPowerSaveActive:)])
                [controller setPowerSaveActive:YES];
            if ([controller respondsToSelector:@selector(setCPULevel:)])
                [controller setCPULevel:kLowPowerCPULevel]; // 调整为 Level 4 压制到 1380-1428MHz

            // 限制 CPU Power Target 防止突发超频
            if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
                [controller setCPUPowerCeiling:1500 fromDecisionSource:0]; // 限制为 1.5W 功耗上限
            }
            if ([controller respondsToSelector:@selector(updateCPU)])
                [controller updateCPU];
        }
        for (id ppm in [g_applePPMInstances allObjects]) {
            if ([ppm respondsToSelector:@selector(setCPULevel:)])
                [ppm setCPULevel:kLowPowerCPULevel];
            if ([ppm respondsToSelector:@selector(updateCPU)])
                [ppm updateCPU];
        }
    }
    g_applyingLowPower = NO;
}

static void restoreFullPowerToControllers(void) {
    if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
    g_restoringFullPower = YES;
    @autoreleasepool {
        if (g_commonProduct) {
            if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)])
                [g_commonProduct setCPMSMitigationsEnabled:NO]; // 彻底关闭 CPMS 抑制
            if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)])
                [g_commonProduct setCPULevel:0]; // 恢复 Level 0 Unrestricted
        }
        for (id controller in [g_mitigationControllers allObjects]) {
            if ([controller respondsToSelector:@selector(setPowerSaveActive:)])
                [controller setPowerSaveActive:NO];
            if ([controller respondsToSelector:@selector(setCPULevel:)])
                [controller setCPULevel:0]; // 恢复 Level 0
            if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
                [controller setCPUPowerCeiling:kUnrestrictedPowerLimitMW fromDecisionSource:0];
            }
            if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)]) {
                [controller setCPUPowerFloor:0 fromDecisionSource:0]; // 清空 floor 限制
            }
            if ([controller respondsToSelector:@selector(setPackagePowerBudgetDirect:details:)]) {
                [controller setPackagePowerBudgetDirect:kUnrestrictedPowerLimitMW details:nil];
            }
            if ([controller respondsToSelector:@selector(updateCPU)])
                [controller updateCPU];
            if ([controller respondsToSelector:@selector(updateGPU)])
                [controller updateGPU];
        }
        for (id ppm in [g_applePPMInstances allObjects]) {
            if ([ppm respondsToSelector:@selector(setCPULevel:)])
                [ppm setCPULevel:0];
            if ([ppm respondsToSelector:@selector(updateCPU)])
                [ppm updateCPU];
        }
    }

    // 强制驱动 CPU 调频器触发一次 Full Boost 重新评价
    CPUthermalForceNominalCombined();
    g_restoringFullPower = NO;
}

static void startKeepAliveTimer(void) {
    if (g_keepAliveTimer) {
        dispatch_source_cancel(g_keepAliveTimer);
        g_keepAliveTimer = NULL;
    }

    // 原生温控模式不启动保活，放行系统行为
    if (isOffMode()) return;

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

static void loadPrefs(void);

static void applyCurrentPowerModeToRuntime(void) {
    loadPrefs(); // 确保读到最新的 powerMode

    // 清除 SC 热压力覆盖，恢复原生热压力判断 (对齐 insulation 全模式行为:
    // off/low/full 三种模式 setter 均调用 insulationSetThermalMitigationsEnabled(YES))
    CPUthermalRestoreNativeThermalPressure();

    if (isOffMode()) {
        // 原生温控：停止保活，放行所有拦截
        if (g_keepAliveTimer) {
            dispatch_source_cancel(g_keepAliveTimer);
            g_keepAliveTimer = NULL;
        }
        return;
    }
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
        if ([mode isEqualToString:S("off")]) {
            g_powerMode = CPUthermalPowerModeOff;
        } else if ([mode isEqualToString:S("lowPower")]) {
            g_powerMode = CPUthermalPowerModeLow;
        } else {
            g_powerMode = CPUthermalPowerModeFull;
        }
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

// 温度读取 selector (0x10-0x1F) — 拦截并伪装正常温度
#define SELECTOR_IS_TEMP(s)       ((s) >= 0x10 && (s) <= 0x1F)
// 降频/缓解操作 selector (0x20-0x5F) — 拦截 (0x60-0x6F 紧急保护不拦截)
#define SELECTOR_IS_MITIGATION(s) ((s) >= 0x20 && (s) <= 0x5F)

// 热管理 IOKit 服务名 — 完整列表 (对齐 CPU(1) g_hotServices)
static const char *g_hotServices[] = {
    "AppleSPU", "AppleSPU.original",
    "AppleARMPlatform",
    "pmu", "ApplePMGR",
    NULL
};

static BOOL serviceIsThermal(io_service_t service) {
    io_name_t name;
    if (IORegistryEntryGetName(service, name) != KERN_SUCCESS) return NO;
    for (int i = 0; g_hotServices[i]; i++) {
        if (strcmp(name, g_hotServices[i]) == 0) return YES;
    }
    return NO;
}

%hookf(kern_return_t, IOServiceOpen, io_service_t service, task_t task, uint32_t type, io_connect_t *connect) {
    kern_return_t ret = %orig;
    if (ret == KERN_SUCCESS) {
        trackConnection(*connect, serviceIsThermal(service));
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
        // 温度读取 selector — 输出伪装为 36°C 正常温度
        if ((shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) && SELECTOR_IS_TEMP(selector)) {
            if (output && outputCnt && *outputCnt > 0) {
                for (uint32_t i = 0; i < MIN(*outputCnt, 4); i++) {
                    output[i] = 36000;  // 36°C — 永远显示正常温度
                }
            }
            return KERN_SUCCESS;
        }
        // 降频/缓解操作 selector — 直接拦截
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
    if (g_enabled && g_cpuProtection && !isOffMode() && !isTemperatureAboveSafetyCeiling()) {
        NSString *ks = [(__bridge NSString *)key lowercaseString];

        // CPU 性能/频率/降频属性写入 — 阻止系统降频 (对齐 CPU(1) 完整键列表)
        static NSArray *cpuKeys;
        static dispatch_once_t onceCPU;
        dispatch_once(&onceCPU, ^{
            cpuKeys = @[S("cpu"), S("freq"), S("frequency"), S("performance"),
                        S("throttle"), S("mitigation"), S("speed"), S("limit")];
        });
        for (NSString *k in cpuKeys) {
            if ([ks containsString:k]) return KERN_SUCCESS;
        }

        // 亮度/背光属性写入 — 阻止温控降亮度
        if (g_thermalPreventDimmingEnabled) {
            static NSArray *brightKeys;
            static dispatch_once_t onceBright;
            dispatch_once(&onceBright, ^{
                brightKeys = @[S("brightness"), S("backlight")];
            });
            for (NSString *k in brightKeys) {
                if ([ks containsString:k]) return KERN_SUCCESS;
            }
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
    if (!isOffMode()) {
        [self putDeviceInThermalSimulationMode:S("nominal")];
    }
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

- (void)updatePowerzoneTelemetry {
    if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) return; // 阻止功率域遥测触发降频
    %orig;
}

- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
    if (shouldApplyFullCPUProtection()) { %orig(NO); return; } // CPMS 强行关闭
    if (shouldApplyLowPowerLimit()) { %orig(YES); return; }
    %orig(enabled);
}

- (void)setCPULevel:(int)level {
    if (g_restoringFullPower) { %orig(level); return; }
    if (shouldApplyLowPowerLimit()) { %orig(kLowPowerCPULevel); return; }
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
    if (g_thermalBlockNotifPopup && !isOffMode()) return; // 屏蔽高温弹窗
    %orig;
}

// 阻止热压力等级升级（非满血模式下也放行升级，off 模式完全放行）
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force {
    if (g_enabled && !isOffMode()) {
        if (!isTemperatureAboveSafetyCeiling()) {
            %orig(notification, NO); // 强制阻止热压力升级
            return;
        }
    }
    %orig(notification, force);
}

// 阻止轻度热压力强制
- (BOOL)shouldEnforceLightThermalPressure {
    if (g_enabled && !isOffMode()) {
        if (!isTemperatureAboveSafetyCeiling()) return NO;
    }
    return %orig;
}

// 阻止潜在强制热等级（满血/低功耗均返回 nominal）
- (int)getPotentialForcedThermalLevel:(id)component {
    if ((shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit())) {
        if (!isTemperatureAboveSafetyCeiling()) return 0;
    }
    return %orig(component);
}

// 阻止潜在强制热压力等级
- (int)getPotentialForcedThermalPressureLevel {
    if ((shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit())) {
        if (!isTemperatureAboveSafetyCeiling()) return 0;
    }
    return %orig;
}

// 屏蔽系统散热/电池服务建议（如"降低亮度"提示）
- (id)getBatteryServiceSuggestion:(id)suggestion {
    id result = %orig(suggestion);
    if (g_enabled && g_thermalBlockNotifPopup && !isOffMode()) {
        if (!isTemperatureAboveSafetyCeiling()) return nil;
    }
    return result;
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

- (void)readReleaseRateForAllComponents {
    if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) return; // 阻止全组件释放速率评估
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
    if (shouldApplyLowPowerLimit()) { %orig(kLowPowerCPULevel); return; }
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

- (void)setPowerSaveActive:(BOOL)active {
    trackPowerController(self);
    if (shouldApplyLowPowerLimit()) { %orig(YES); return; }
    if (shouldApplyFullCPUProtection()) { %orig(NO); return; }
    %orig(active);
}

- (void)setCPULevel:(int)level {
    if (shouldApplyLowPowerLimit()) { %orig(kLowPowerCPULevel); return; }
    if (shouldApplyFullCPUProtection()) { %orig(0); return; }
    %orig(level);
}

// 解除最大 CPU 功率目标限制（insulation max 模式语义）
- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
    if (shouldApplyFullCPUProtection()) { %orig(1000, legacy, property); return; }
    %orig(target, legacy, property);
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
    if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW, source); return; }
    %orig(ceiling, source);
}

- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
    if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW, source); return; }
    if (shouldApplyLowPowerLimit()) { %orig(floor / 2, source); return; } // 低功耗: 降低功耗下限 (对齐 insulation)
    %orig(floor, source);
}

- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
    if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW, source); return; }
    %orig(ceiling, source);
}

- (void)setPackagePowerBudgetDirect:(int)budget details:(id)details {
    if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW, details); return; }
    %orig(budget, details);
}

// 更新 CPU 前先强制应用解封 override (对齐 insulation updateCPU hook)
- (void)updateCPU {
    if (shouldApplyFullCPUProtection()) {
        [self setCPULevel:0];
        [self setCPUPowerCeiling:kUnrestrictedPowerLimitMW fromDecisionSource:0];
        [self setMaxCPUPowerTarget:1000 useLegacyPath:NO setProperty:0];
    }
    %orig;
}

// 目标功率 getter — 报告无热限制 (fullPower) / 至少 50% 目标 (lowPower)
- (int)getCPUTargetPower {
    int orig = %orig;
    if (shouldApplyFullCPUProtection()) return 0;
    if (shouldApplyLowPowerLimit()) return MAX(orig, 50);
    return orig;
}

- (int)getGPUTargetPower {
    int orig = %orig;
    if (shouldApplyFullCPUProtection()) return 0;
    return orig;
}
%end

%hook HidSensors
- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2 {
    if (g_enabled && g_thermalBlockNotifPopup && !isOffMode()) return;
    %orig;
}
%end

// --- notify_post — 拦截高温 Darwin 广播 ---
%hookf(uint32_t, notify_post, const char *name) {
    if (g_enabled && g_thermalBlockNotifPopup && !isOffMode() && name) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSString *ns = S(name);
            if ([ns containsString:S("thermalstate")] ||
                ([ns containsString:S("thermal")] && [ns containsString:S("high")])) {
                return NOTIFY_STATUS_OK;
            }
        }
    }
    return %orig(name);
}

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
// MARK: - _getConfigurationFor C 函数钩子 (热阈值 +5°C 延迟触发)
// ============================================================================
static NSDictionary* (*orig_getConfigurationFor)(NSString *key) = NULL;

static NSDictionary* new_getConfigurationFor(NSString *key) {
    NSDictionary *config = orig_getConfigurationFor(key);
    if (!config || isOffMode() || !g_cpuProtection) return config;

    // 安全阀: 超过阈值不修改
    if (isTemperatureAboveSafetyCeiling()) return config;

    @autoreleasepool {
        NSMutableDictionary *modified = [config mutableCopy];
        if (!modified) return config;

        // 提高所有热等级触发阈值 +5°C (5000 毫摄氏度)
        static NSArray *tempThresholdKeys;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            tempThresholdKeys = @[
                S("thermalThresholds"),
                S("dieTemperatureThresholds"),
                S("skinTemperatureThresholds"),
                S("componentTemperatureThresholds"),
                S("hotTemperatureThresholds")
            ];
        });

        for (NSString *tk in tempThresholdKeys) {
            id thresholds = modified[tk];
            if ([thresholds isKindOfClass:[NSArray class]]) {
                NSMutableArray *newThresholds = [NSMutableArray array];
                for (NSNumber *val in (NSArray *)thresholds) {
                    [newThresholds addObject:@([val longLongValue] + 5000)];
                }
                modified[tk] = newThresholds;
            } else if ([thresholds isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *newDict = [NSMutableDictionary dictionary];
                [(NSDictionary *)thresholds enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                    if ([v isKindOfClass:[NSNumber class]]) {
                        newDict[k] = @([v longLongValue] + 5000);
                    } else {
                        newDict[k] = v;
                    }
                }];
                modified[tk] = newDict;
            }
        }

        return [modified copy];
    }
}

// ============================================================================
// MARK: - 热配置 plist 修补 (锁定背光亮度，防温控降亮度)
// ============================================================================
static void patchThermalPlistDict(NSMutableDictionary *dict) {
    if (!g_enabled || !g_thermalPreventDimmingEnabled || isOffMode()) return;

    NSMutableDictionary *backlight = [[dict objectForKey:S("backlightComponentControl")] mutableCopy];
    if (!backlight) return;

    // 锁定背光亮度数组 — 所有热等级亮度一致（不降亮度）
    NSMutableArray *brightnessArr = [[backlight objectForKey:S("BacklightBrightness")] mutableCopy];
    if (brightnessArr.count > 1) {
        id first = brightnessArr[0];
        for (NSUInteger i = 1; i < brightnessArr.count; i++) {
            brightnessArr[i] = first;
        }
        backlight[S("BacklightBrightness")] = brightnessArr;
    }

    // 锁定背光功耗数组
    NSMutableArray *powerArr = [[backlight objectForKey:S("BacklightPower")] mutableCopy];
    if (powerArr.count > 1) {
        id first = powerArr[0];
        for (NSUInteger i = 1; i < powerArr.count; i++) {
            powerArr[i] = first;
        }
        backlight[S("BacklightPower")] = powerArr;
    }

    // 禁用 CPMS（CPU/GPU 电源管理子系统）— 对齐 CPU(1)，安全阀由 IOKit 层独立保证
    backlight[S("expectsCPMSSupport")] = @0;

    dict[S("backlightComponentControl")] = backlight;
}

// --- NSDictionary: 拦截 thermal plist 加载并修补 ---
// 注意: hook 系统类有风险，仅在防暗屏保护开启且非 off 模式时实际执行
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
    id res = %orig;
    if (g_enabled && g_thermalPreventDimmingEnabled && !isOffMode() && [path isKindOfClass:[NSString class]]) {
        NSString *pathStr = (NSString *)path;
        if ([pathStr containsString:S("/System/Library/ThermalMonitor/")]) {
            if (!isTemperatureAboveSafetyCeiling()) {
                NSMutableDictionary *patched = [res mutableCopy];
                if (patched) {
                    patchThermalPlistDict(patched);
                    return patched;
                }
            }
        }
    }
    return res;
}

%end

// ============================================================================
// MARK: - Puppet 热模拟事件 (对齐 CPU(1))
// ============================================================================
static void executePuppetEvent(void) {
    if (!g_commonProduct) return;
    @autoreleasepool {
        NSDictionary *prefs = CPUthermalReadPrefs();
        NSString *level = prefs[S("thermalPuppetValue")] ?: S("nominal");
        [g_commonProduct putDeviceInThermalSimulationMode:level];
        NSLog(@"[CPUthermal] Puppet 事件: 热模式设为 %@", level);
    }
}

static void onPuppetEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    executePuppetEvent();
}

// ============================================================================
// MARK: - 构造函数 (%ctor)
// ============================================================================
%ctor {
    @autoreleasepool {
        CPUthermalProbeMarkLoaded(S("ctor.begin"));
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

        // 绑定 _getConfigurationFor C 函数 Hook (热阈值 +5°C)
        void *monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor", RTLD_NOW | RTLD_GLOBAL);
        if (monitor) {
            void *getConfig = dlsym(monitor, "_getConfigurationFor");
            if (getConfig) {
                MSHookFunction(getConfig, (void *)new_getConfigurationFor, (void **)&orig_getConfigurationFor);
            }
        }

        if (!isOffMode()) {
            CPUthermalForceNominalCombined();
        }

        // 注册设置重载 Darwin 通知
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            CFNotificationCenterAddObserver(c, NULL, (CFNotificationCallback)loadPrefs,
                (__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(c, NULL, (CFNotificationCallback)applyCurrentPowerModeToRuntime,
                (__bridge CFStringRef)S(kCPUthermalPowerModeChangedNotifC), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            // Puppet 热模拟事件 (对齐 CPU(1))
            CFNotificationCenterAddObserver(c, NULL, onPuppetEvent,
                (__bridge CFStringRef)S("com.huayuarc.CPUthermal.puppet"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        applyCurrentPowerModeToRuntime();
        CPUthermalProbeMarkLoaded(S("ctor.done"));
    }
}
