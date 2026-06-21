#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#include <roothide.h>
#import <IOKit/IOKitLib.h>
#import <SystemConfiguration/SCPreferences.h>
#import <sys/sysctl.h>

// ============================================================================
// CPUthermal — 温控插件（完全版）
//
// 双防护层设计:
//   第1层 (IOKit): 拦截传感器温度读取、降频操作、属性写入、Darwin 通知广播
//   第2层 (ObjC):  钩住 thermalmonitord 内部类决策方法，阻止热缓解动作
//
// 冲突避免原则:
//   - 传感器读数拦截只走 IOKit，不走 ObjC
//   - 不 hook putDeviceInThermalSimulationMode: (CPUthermal 调用方)
//   - 所有新增 hook 有独立开关
//   - 保留紧急热保护安全阀 (75°C+ 不拦截)
//
// 注意: 禁止使用 @"" ObjC 字符串常量（roothide 重映射会破坏 __cfstring）
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================================

// 动态创建 NSString 的辅助宏 — 避免编译期 __cfstring
#define S(str) [NSString stringWithUTF8String:(str)]

// 前向声明 — 供 %hook ThermalManager initProduct 提前调用
static void applyLowPowerSimulation(void);
static void startLowPowerTimer(void);
static void stopLowPowerTimer(void);
static void applySuppressTempPopup(BOOL enable);
static void reloadSettings(void);

// ============================================================================
// ObjC 类声明（thermalmonitord 内部类，class-dump 获取）
// ============================================================================
@interface CommonProduct : NSObject
- (id)initProduct:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)tryTakeAction;
- (void)simulateLightThermalPressure;
- (void)updatePowerzoneTelemetry;
@end

@interface HidSensors : NSObject
+ (id)sharedInstance;
- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2;
@end

// ============================================================================
// 新增: 1.dylib 分析发现的额外类声明
// ============================================================================
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
// === 模拟低电频率所需方法 (适配自 Insulation 逆向) ===
- (void)setCPULowPowerTarget:(int)target;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(id)source;
- (void)setPackageLowPowerTarget;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setCPULevel:(int)level;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setPackagePowerFloor:(int)floor fromDecisionSource:(id)source;
- (void)setCPUPowerZoneTarget:(int)target;
- (void)setPackagePowerZoneTarget;
- (void)setPackageLowPowerTarget;
- (void)updateCPU;
- (void)updateGPU;
- (void)updatePackage;
- (id)getThermalSuggestion:(id)suggestion;
- (int)getGPUTargetPower;
- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setMaxPackagePower:(int)power;
- (void)thermalMitigation:(id)mitigation;
- (id)thermalPressure:(id)pressure;
- (id)thermalSuggestion:(id)suggestion;
- (void)updatePowerzoneTelemetry;
@end

@interface ThermalControl : NSObject
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2;
- (id)findCC:(id)component;
- (float)dieTempFilteredMaxAverage;
- (float)getHighestSkinTemp;
- (float)thermalSensorValuesMaxFromIndexSet:(id)indexSet;
- (void)copyDieTempSensorIndexSetForFourthChar:(char)c sensors:(id)sensors;
- (BOOL)powerSaveActive;
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (id)initWithParams:(id)params;
- (void)updatePowerParameters:(id)params;
@end

@interface ThermalDecisionTable : NSObject
- (id)initDecisionTable:(id)table;
@end

@interface PIDController : NSObject
- (id)initPIDWith:(id)params;
@end

@interface HotspotController : NSObject
- (id)initWithParams:(id)params aggdController:(id)aggd;
@end

@interface CommonAggdController : NSObject
- (id)initWithParams:(id)params product:(id)product;
@end

// ============================================================================
// 配置
// ============================================================================
static BOOL g_enabled               = YES; // 总开关（默认开启）
static BOOL g_cpuProtection         = YES; // CPU 性能保护(降频/决策树/控制力度/配置表)
static BOOL g_brightnessProtection  = YES; // 屏幕亮度保护(降亮度/背光配置)
static BOOL g_thermalStateProtection= YES; // 热状态封锁(Nominal/热压力/强制级别)
static BOOL g_blockHidEvents        = YES; // 阻止 HID 温度事件
static BOOL g_keepCPSMAlive         = NO;  // 保留 CPMS 紧急保护(安全阀) 默认关闭
static BOOL g_lowPowerSimulation    = NO;  // 模拟低电频率（主动压低 CPU/Package 功率）
static BOOL g_suppressTempPopup     = NO;  // 禁温度计弹窗（阻断热通知 + SCPreferences）

// 温度安全阀 — 超过此值不拦截任何保护
static const int64_t kSafetyTempThreshold = 75000; // 75°C (毫摄氏度)

// 注意: 用 C 字符串而非 ObjC 常量，避免 roothide 重映射破坏 __cfstring
static const char *kPrefPathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";
static CommonProduct *g_commonProduct = nil;
static ThermalManager *g_thermalManager = nil;
static dispatch_source_t g_lowPowerTimer = NULL;

// 核心修复：低电模拟主动下发保护锁状态，避免被自身 Hook 拦截
static BOOL g_isApplyingSimulation = NO;

static void loadPrefs(void) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:jbroot(kPrefPathC)];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!d) return;
        g_enabled               = [d[S("enabled")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_cpuProtection         = [d[S("cpuProtection")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_brightnessProtection  = [d[S("brightnessProtection")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_thermalStateProtection= [d[S("thermalStateProtection")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_blockHidEvents        = [d[S("blockHidEvents")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_keepCPSMAlive         = [d[S("keepCPMSAlive")] ?: [NSNumber numberWithBool:NO] boolValue];
        g_lowPowerSimulation    = [d[S("lowPowerSimulation")] ?: [NSNumber numberWithBool:NO] boolValue];
        g_suppressTempPopup     = [d[S("suppressTempPopup")] ?: [NSNumber numberWithBool:NO] boolValue];
    }
}

// ============================================================================
// 热管理 IOKit 服务名
// ============================================================================
static const char *g_hotServices[] = {
    "AppleSPU", "AppleSPU.original",
    "AppleARMPlatform",
    "pmu", "ApplePMGR",
    NULL
};

#define SELECTOR_IS_TEMP(s)        ((s) >= 0x10 && (s) <= 0x1F)
#define SELECTOR_IS_MITIGATION(s)  (((s) >= 0x40 && (s) <= 0x5F) || (s) == 0x30 || (s) == 0x31)
#define SELECTOR_IS_CRITICAL(s)    ((s) >= 0x60 && (s) <= 0x6F)  // 紧急保护 — 不拦截

// ============================================================================
// connection 追踪
// ============================================================================
#define MAX_CONN 64

typedef struct {
    io_connect_t conn;
    BOOL         isThermal;
} ConnEntry;

static ConnEntry g_conns[MAX_CONN];
static int g_connCount = 0;

static void trackConnection(io_connect_t conn, BOOL thermal) {
    if (g_connCount >= MAX_CONN) return;
    g_conns[g_connCount].conn     = conn;
    g_conns[g_connCount].isThermal = thermal;
    g_connCount++;
}

static BOOL isThermalConnection(io_connect_t conn) {
    for (int i = 0; i < g_connCount; i++) {
        if (g_conns[i].conn == conn) return g_conns[i].isThermal;
    }
    return NO;
}

static BOOL serviceIsThermal(io_service_t service) {
    io_name_t name;
    if (IORegistryEntryGetName(service, name) != KERN_SUCCESS) return NO;
    for (int i = 0; g_hotServices[i]; i++) {
        if (strcmp(name, g_hotServices[i]) == 0) return YES;
    }
    return NO;
}

// ============================================================================
// 温度安全阀检查
// ============================================================================
static BOOL isTemperatureAboveSafetyCeiling(void) {
    if (!g_keepCPSMAlive) return NO;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleARMPlatform");
    if (!matching) return NO;

    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
    if (!service) return NO;

    CFTypeRef temp = IORegistryEntryCreateCFProperty(service, CFSTR("temperature"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);

    if (!temp) return NO;

    int64_t tempVal = 0;
    if (CFNumberGetValue((CFNumberRef)temp, kCFNumberSInt64Type, &tempVal)) {
        CFRelease(temp);
        return tempVal >= kSafetyTempThreshold;
    }

    CFRelease(temp);
    return NO;
}

// ============================================================================
// IOKit 层钩子
// ============================================================================

// --- IOServiceOpen — 追踪 thermal connection ---
%hookf(kern_return_t, IOServiceOpen, io_service_t service, task_t task, uint32_t type, io_connect_t *connect) {
    kern_return_t ret = %orig;
    if (ret == KERN_SUCCESS) {
        trackConnection(*connect, serviceIsThermal(service));
    }
    return ret;
}

// --- IOConnectCallMethod — 拦截温度读取 + 降频操作 ---
%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
    // 修复：如果内部正在下发低电模拟频率，不拦截下发请求
    if (g_isApplyingSimulation) {
        return %orig;
    }

    if (!g_enabled || !isThermalConnection(connection)) {
        return %orig;
    }

    // 紧急保护 — 任何情况都不拦截 (安全阀)
    if (SELECTOR_IS_CRITICAL(selector)) {
        return %orig;
    }

    // 超过 75°C 时放行所有保护（安全阀生效）
    if (isTemperatureAboveSafetyCeiling()) {
        return %orig;
    }

    if (g_thermalStateProtection && SELECTOR_IS_TEMP(selector)) {
        if (output && outputCnt && *outputCnt > 0) {
            for (uint32_t i = 0; i < MIN(*outputCnt, 4); i++) {
                output[i] = 36000; // 36°C — 永远显示正常温度
            }
        }
        return KERN_SUCCESS;
    }
    if (g_cpuProtection && SELECTOR_IS_MITIGATION(selector)) {
        return KERN_SUCCESS;
    }
    return %orig;
}

// --- IOServiceSetProperty — 阻止写降频/降亮度属性 ---
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;
static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    // 修复：内部主动模拟限频时放行，不拦截
    if (g_isApplyingSimulation || !g_enabled) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    // 安全阀: 超过阈值不拦截
    if (isTemperatureAboveSafetyCeiling()) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    NSString *ks = (__bridge NSString *)key;
    if (g_cpuProtection) {
        static NSArray *cpuKeys;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            cpuKeys = @[S("cpu"), S("CPU"), S("freq"), S("Freq"), S("frequency"), S("performance"), S("throttle"), S("mitigation"), S("speed"), S("limit")];
        });
        for (NSString *k in cpuKeys) {
            if ([ks containsString:k]) return KERN_SUCCESS;
        }
    }
    if (g_brightnessProtection) {
        static NSArray *brightKeys;
        static dispatch_once_t once2;
        dispatch_once(&once2, ^{
            brightKeys = @[S("brightness"), S("Brightness"), S("backlight"), S("Backlight")];
        });
        for (NSString *k in brightKeys) {
            if ([ks containsString:k]) return KERN_SUCCESS;
        }
    }
    return orig_IOServiceSetProperty(service, key, value);
}

// --- IORegistryEntryCreateCFProperty — 返回正常值 ---
%hookf(CFTypeRef, IORegistryEntryCreateCFProperty, io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    if (g_isApplyingSimulation) return %orig;
    if (!g_enabled || !g_thermalStateProtection) return %orig;
    if (isTemperatureAboveSafetyCeiling()) return %orig;

    NSString *ks = (__bridge NSString *)key;
    if ([ks localizedCaseInsensitiveContainsString:S("temperature")] ||
        [ks localizedCaseInsensitiveContainsString:S("thermal-level")] ||
        [ks localizedCaseInsensitiveContainsString:S("hot-level")] ||
        [ks localizedCaseInsensitiveContainsString:S("thermalstate")]) {
        int zero = 0;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
    }
    if ([ks localizedCaseInsensitiveContainsString:S("freq")] ||
        [ks localizedCaseInsensitiveContainsString:S("speed")] ||
        [ks localizedCaseInsensitiveContainsString:S("performance-state")] ||
        [ks localizedCaseInsensitiveContainsString:S("cpu-frequency")]) {
        if (g_lowPowerSimulation) {
            long long lowFreq = 1200000000LL; // 低电模拟: 返回低频 (1.2 GHz)
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &lowFreq);
        } else {
            int max = INT_MAX;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &max);
        }
    }
    if ([ks localizedCaseInsensitiveContainsString:S("brightness")] ||
        [ks localizedCaseInsensitiveContainsString:S("backlight")]) {
        float one = 1.0;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &one);
    }
    return %orig;
}

// --- notify_post — 拦截高温广播 ---
%hookf(uint32_t, notify_post, const char *name) {
    if (g_isApplyingSimulation) return %orig;
    if (g_enabled && (g_thermalStateProtection || g_suppressTempPopup) && name) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSString *ns = [NSString stringWithUTF8String:name];
            if ([ns containsString:S("thermalstate")] || ([ns containsString:S("thermal")] && [ns containsString:S("high")])) {
                return NOTIFY_STATUS_OK;
            }
            if (g_suppressTempPopup && [ns containsString:S("thermalpressurelevel")]) {
                return NOTIFY_STATUS_OK;
            }
        }
    }
    return %orig;
}

// ============================================================================
// sysctlbyname hook
// ============================================================================
%hookf(int, sysctlbyname, const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (g_enabled && g_lowPowerSimulation && name && !newp) {
        if (strcmp(name, "hw.cpufrequency") == 0 || strcmp(name, "hw.cpufrequency_max") == 0) {
            long long fakeFreq = 1200000000LL;
            if (oldp) {
                if (*oldlenp >= sizeof(long long)) {
                    memcpy(oldp, &fakeFreq, sizeof(long long));
                    *oldlenp = sizeof(long long);
                } else {
                    *oldlenp = sizeof(long long);
                }
            } else {
                *oldlenp = sizeof(long long);
            }
            return 0;
        }
        if (strcmp(name, "machdep.cpu.brand_string") == 0) {
            const char *fakeBrand = "Apple A15 Bionic @ 1.20 GHz";
            size_t brandLen = strlen(fakeBrand) + 1;
            if (oldp) {
                if (*oldlenp >= brandLen) {
                    strcpy((char *)oldp, fakeBrand);
                    *oldlenp = brandLen;
                } else {
                    *oldlenp = brandLen;
                }
            } else {
                *oldlenp = brandLen;
            }
            return 0;
        }
    }
    return %orig(name, oldp, oldlenp, newp, newlen);
}

// ============================================================================
// ObjC 类钩子（第1层: CommonProduct / HidSensors）
// ============================================================================
%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig;
    if (g_enabled) {
        g_commonProduct = self;
        [self putDeviceInThermalSimulationMode:S("nominal")];
        NSLog(@"[CPUthermal] CommonProduct init, 已重置热状态为 nominal");
    }
    return res;
}

- (void)tryTakeAction {
    if (g_isApplyingSimulation) {
        %orig;
        return;
    }
    if (g_enabled && g_cpuProtection) {
        return;
    }
    %orig;
}

- (void)simulateLightThermalPressure {
    if (g_isApplyingSimulation) {
        %orig;
        return;
    }
    if (g_enabled && g_cpuProtection) {
        return;
    }
    %orig;
}

- (void)updatePowerzoneTelemetry {
    if (g_isApplyingSimulation) {
        %orig;
        return;
    }
    if (g_enabled && g_cpuProtection) {
        return;
    }
    %orig;
}

%end

%hook HidSensors

- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2 {
    if (g_enabled && g_blockHidEvents) {
        return;
    }
    %orig;
}

%end

// ============================================================================
// ObjC 类钩子（第2层: ThermalManager 决策层）
// ============================================================================
%hook ThermalManager

- (void)evaluateDecisionTree {
    if (g_isApplyingSimulation) {
        %orig;
        return;
    }
    if (g_enabled && g_cpuProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
            return;
        }
    }
    %orig;
}

- (BOOL)shouldEnforceLightThermalPressure {
    if (g_isApplyingSimulation) return %orig;
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止 enforceLightThermalPressure");
            return NO;
        }
    }
    return %orig;
}

- (float)getReleaseRateForComponent:(id)component {
    if (g_isApplyingSimulation) return %orig(component);
    if (g_enabled && g_cpuProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            float rate = %orig(component);
            if (rate > 0.5) {
                rate = rate * 0.5;
            }
            NSLog(@"[CPUthermal] 软化释放速率: %@ -> %.2f", component, rate);
            return rate;
        }
    }
    return %orig(component);
}

- (int)getPotentialForcedThermalLevel:(id)component {
    if (g_isApplyingSimulation) return %orig(component);
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 覆盖强制热级别: %@ -> 0 (nominal)", component);
            return 0;
        }
    }
    return %orig(component);
}

- (int)getPotentialForcedThermalPressureLevel {
    if (g_isApplyingSimulation) return %orig;
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 覆盖强制热压力级别 -> 0");
            return 0;
        }
    }
    return %orig;
}

- (id)getBatteryServiceSuggestion:(id)suggestion {
    if (g_isApplyingSimulation) return %orig(suggestion);
    id result = %orig(suggestion);
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 拦截 ThermalManager 散热建议");
            return nil;
        }
    }
    return result;
}

- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table {
    id res = %orig(components, hotspots, table);
    if (res && g_enabled) {
        g_thermalManager = res;
        NSLog(@"[CPUthermal] ThermalManager 已初始化");
        if (g_lowPowerSimulation) {
            applyLowPowerSimulation();
            startLowPowerTimer();
        }
    }
    return res;
}

- (void)updateThermalNotification:(id)notification {
    if (g_isApplyingSimulation) {
        %orig;
        return;
    }
    if (g_enabled && (g_thermalStateProtection || g_suppressTempPopup)) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止热通知: %@", notification);
            return;
        }
    }
    %orig;
}

- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force {
    if (g_isApplyingSimulation) {
        %orig(notification, force);
        return;
    }
    if (g_enabled && (g_thermalStateProtection || g_suppressTempPopup)) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止热压力升级: %@ force:%d", notification, force);
            %orig(notification, NO);
            return;
        }
    }
    %orig;
}

%end

// --- ThermalControl: hook 控制力度计算 ---
%hook ThermalControl

- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
    if (g_isApplyingSimulation) return %orig(trigger, arg2);
    if (g_enabled && g_cpuProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            float effort = %orig(trigger, arg2);
            float newEffort = effort * 0.5;
            if (newEffort < 0 && effort > 0) newEffort = 0;
            NSLog(@"[CPUthermal] 软化控制力度: %.2f -> %.2f", effort, newEffort);
            return newEffort;
        }
    }
    return %orig(trigger, arg2);
}

- (void)actionComponentControl {
    if (g_isApplyingSimulation) {
        %orig;
        return;
    }
    if (g_enabled && g_cpuProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止 actionComponentControl");
            return;
        }
    }
    %orig;
}

- (void)readReleaseRateForAllComponents {
    if (g_isApplyingSimulation) {
        %orig;
        return;
    }
    if (g_enabled && g_cpuProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止 readReleaseRateForAllComponents");
            return;
        }
    }
    %orig;
}

%end

// ============================================================================
// C 函数钩子: _getConfigurationFor
// ============================================================================
static NSDictionary* (*orig_getConfigurationFor)(NSString *key) = NULL;
static NSDictionary* new_getConfigurationFor(NSString *key) {
    NSDictionary *config = orig_getConfigurationFor(key);
    if (!g_enabled || !g_cpuProtection || !config) return config;
    if (isTemperatureAboveSafetyCeiling()) return config;

    @autoreleasepool {
        NSMutableDictionary *modified = [config mutableCopy];
        if (!modified) return config;

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
                    int64_t raised = [val longLongValue] + 5000;
                    [newThresholds addObject:@(raised)];
                }
                modified[tk] = newThresholds;
            } else if ([thresholds isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *newDict = [NSMutableDictionary dictionary];
                [(NSDictionary *)thresholds enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                    if ([v isKindOfClass:[NSNumber class]]) {
                        int64_t raised = [v longLongValue] + 5000;
                        newDict[k] = @(raised);
                    } else {
                        newDict[k] = v;
                    }
                }];
                modified[tk] = newDict;
            }
        }

        NSLog(@"[CPUthermal] 已修改热配置表: %@", key);
        return [modified copy];
    }
}

// ============================================================================
// 热配置 plist 修补
// ============================================================================
static void patchThermalPlistDict(NSMutableDictionary *dict) {
    if (!g_enabled || !g_brightnessProtection) return;
    NSMutableDictionary *backlight = [[dict objectForKey:S("backlightComponentControl")] mutableCopy];
    if (!backlight) return;

    NSMutableArray *brightnessArr = [[backlight objectForKey:S("BacklightBrightness")] mutableCopy];
    if (brightnessArr.count > 1) {
        id first = brightnessArr[0];
        for (NSUInteger i = 1; i < brightnessArr.count; i++) {
            brightnessArr[i] = first;
        }
        backlight[S("BacklightBrightness")] = brightnessArr;
    }

    NSMutableArray *powerArr = [[backlight objectForKey:S("BacklightPower")] mutableCopy];
    if (powerArr.count > 1) {
        id first = powerArr[0];
        for (NSUInteger i = 1; i < powerArr.count; i++) {
            powerArr[i] = first;
        }
        backlight[S("BacklightPower")] = powerArr;
    }

    if (!g_keepCPSMAlive) {
        backlight[S("expectsCPMSSupport")] = @0;
    }

    dict[S("backlightComponentControl")] = backlight;
}

%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
    id res = %orig;
    if (g_enabled && g_brightnessProtection && [path isKindOfClass:[NSString class]]) {
        NSString *pathStr = (NSString *)path;
        if ([pathStr containsString:S("/System/Library/ThermalMonitor/")]) {
            if (!isTemperatureAboveSafetyCeiling()) {
                NSMutableDictionary *patched = [res mutableCopy];
                if (patched) {
                    patchThermalPlistDict(patched);
                    NSLog(@"[CPUthermal] 已修补热配置 plist: %@", [pathStr lastPathComponent]);
                    return patched;
                }
            }
        }
    }
    return res;
}

%end

// ============================================================================
// 模拟低电频率核心应用逻辑 — 修复锁与决策源
// ============================================================================
static void applyLowPowerSimulation(void) {
    if (!g_thermalManager || !g_enabled) return;
    @autoreleasepool {
        // 关键修复 1：开启保护锁，放行此方法内下发的所有底层 IOKit 和属性调用
        g_isApplyingSimulation = YES;
        NSLog(@"[CPUthermal] 激活模拟低电频率...");

        // 开启省电模式
        [g_thermalManager setPowerSaveActive:YES];
        // 使用正数 1，避免 0 被系统内核解释为"不限制"
        [g_thermalManager setCPULowPowerTarget:1];
        
        // 关键修复 2：决策源改用原生常见源 "CLTM"（或 "SMC"），防止自定义字符串被系统白名单机制拒绝
        [g_thermalManager setCPUPowerCeiling:300 fromDecisionSource:S("CLTM")];
        [g_thermalManager setCPUPowerFloor:100 fromDecisionSource:S("CLTM")];
        
        // Package 低功耗目标与功率控制
        [g_thermalManager setPackageLowPowerTarget];
        [g_thermalManager setPackagePowerCeiling:500 fromDecisionSource:S("CLTM")];
        [g_thermalManager setPackagePowerFloor:200 fromDecisionSource:S("CLTM")];
        
        // Zone 目标压低
        [g_thermalManager setCPUPowerZoneTarget:1];
        [g_thermalManager setPackagePowerZoneTarget];
        
        // GPU 功率限制
        [g_thermalManager setGPUPowerCeiling:300 fromDecisionSource:S("CLTM")];
        // 强制 CPU 调频至最低 Level 0
        [g_thermalManager setCPULevel:0];
        // 限制全局整机功耗上限 500mW
        [g_thermalManager setMaxPackagePower:500];

        // 同步通知各组件生效
        [g_thermalManager updateCPU];
        [g_thermalManager updateGPU];
        [g_thermalManager updatePackage];

        // 关闭保护锁，恢复常规防降频拦截逻辑
        g_isApplyingSimulation = NO;
        NSLog(@"[CPUthermal] 模拟低电频率已应用");
    }
}

// ============================================================================
// 低电模拟定时器
// ============================================================================
static void startLowPowerTimer(void) {
    if (g_lowPowerTimer) return;
    g_lowPowerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    if (!g_lowPowerTimer) return;
    dispatch_source_set_timer(g_lowPowerTimer,
        dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
        3 * NSEC_PER_SEC,
        NSEC_PER_SEC);
    dispatch_source_set_event_handler(g_lowPowerTimer, ^{
        @autoreleasepool {
            if (g_enabled && g_lowPowerSimulation && g_thermalManager) {
                applyLowPowerSimulation();
            }
        }
    });
    dispatch_resume(g_lowPowerTimer);
    NSLog(@"[CPUthermal] 低电模拟定时器已启动 (间隔 3s)");
}

static void stopLowPowerTimer(void) {
    if (g_lowPowerTimer) {
        dispatch_source_cancel(g_lowPowerTimer);
        g_lowPowerTimer = NULL;
        NSLog(@"[CPUthermal] 低电模拟定时器已停止");
    }
}

// ============================================================================
// 禁温度计弹窗
// ============================================================================
static void applySuppressTempPopup(BOOL enable) {
    @autoreleasepool {
        NSLog(@"[CPUthermal] %@ 温度计弹窗", enable ? S("禁用") : S("恢复"));
        void *sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW | RTLD_GLOBAL);
        if (!sc) {
            NSLog(@"[CPUthermal] 无法加载 SystemConfiguration.framework");
            return;
        }

        SCPreferencesRef (*dyn_SCPreferencesCreate)(CFAllocatorRef, CFStringRef, CFStringRef) =
            (SCPreferencesRef (*)(CFAllocatorRef, CFStringRef, CFStringRef))dlsym(sc, "SCPreferencesCreate");
        Boolean (*dyn_SCPreferencesSetValue)(SCPreferencesRef, CFStringRef, CFPropertyListRef) =
            (Boolean (*)(SCPreferencesRef, CFStringRef, CFPropertyListRef))dlsym(sc, "SCPreferencesSetValue");
        Boolean (*dyn_SCPreferencesCommitChanges)(SCPreferencesRef) =
            (Boolean (*)(SCPreferencesRef))dlsym(sc, "SCPreferencesCommitChanges");
        Boolean (*dyn_SCPreferencesApplyChanges)(SCPreferencesRef) =
            (Boolean (*)(SCPreferencesRef))dlsym(sc, "SCPreferencesApplyChanges");
        if (!dyn_SCPreferencesCreate || !dyn_SCPreferencesSetValue ||
            !dyn_SCPreferencesCommitChanges || !dyn_SCPreferencesApplyChanges) {
            NSLog(@"[CPUthermal] dlsym SCPreferences API 失败");
            dlclose(sc);
            return;
        }

        SCPreferencesRef prefs = dyn_SCPreferencesCreate(NULL,
            (__bridge CFStringRef)S("CPUthermal"),
            (__bridge CFStringRef)S("OSThermalStatus"));
        if (!prefs) {
            NSLog(@"[CPUthermal] SCPreferencesCreate 失败");
            dlclose(sc);
            return;
        }

        dyn_SCPreferencesSetValue(prefs, (__bridge CFStringRef)S("OSThermalNotificationEnabled"), enable ? kCFBooleanFalse : kCFBooleanTrue);
        dyn_SCPreferencesSetValue(prefs, (__bridge CFStringRef)S("OSThermalNotificationPersistentlyEnabled"), enable ? kCFBooleanFalse : kCFBooleanTrue);
        dyn_SCPreferencesSetValue(prefs, (__bridge CFStringRef)S("hipOverride"), enable ? kCFBooleanFalse : kCFBooleanTrue);
        dyn_SCPreferencesSetValue(prefs, (__bridge CFStringRef)S("hipPersistentlyEnabled"), enable ? kCFBooleanFalse : kCFBooleanTrue);
        
        Boolean committed = dyn_SCPreferencesCommitChanges(prefs);
        Boolean applied = dyn_SCPreferencesApplyChanges(prefs);
        if (committed && applied) {
            NSLog(@"[CPUthermal] OSThermalStatus.plist 写入成功");
        } else {
            NSLog(@"[CPUthermal] OSThermalStatus.plist 写入失败");
        }
        CFRelease(prefs);
        dlclose(sc);
    }
}

// ============================================================================
// 运行时配置重载
// ============================================================================
static void reloadSettings(void) {
    @autoreleasepool {
        NSLog(@"[CPUthermal] 运行时重载配置...");
        loadPrefs();
        if (!g_enabled) return;

        if (g_lowPowerSimulation && g_thermalManager) {
            applyLowPowerSimulation();
            startLowPowerTimer();
        } else {
            stopLowPowerTimer();
        }

        applySuppressTempPopup(g_suppressTempPopup);
    }
}

// ============================================================================
// Puppet 事件
// ============================================================================
static void executePuppetEvent(void) {
    if (!g_commonProduct) return;
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:jbroot(kPrefPathC)];
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
        NSString *level = prefs[S("thermalPuppetValue")] ?: S("nominal");
        [g_commonProduct putDeviceInThermalSimulationMode:level];
        NSLog(@"[CPUthermal] Puppet 事件: 热模式设为 %@", level);
    }
}

static void onPuppetEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    executePuppetEvent();
}

static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    reloadSettings();
}

// ============================================================================
// %ctor — 构造函数
// ============================================================================
%ctor {
    @autoreleasepool {
        loadPrefs();
        if (!g_enabled) {
            NSLog(@"[CPUthermal] 配置关闭，跳过加载");
            return;
        }

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (iokit) {
            kern_return_t (*ptr)(io_service_t, CFStringRef, CFTypeRef) = (kern_return_t (*)(io_service_t, CFStringRef, CFTypeRef))dlsym(iokit, "IOServiceSetProperty");
            if (ptr) {
                MSHookFunction((void *)ptr, (void *)hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
                NSLog(@"[CPUthermal] IOServiceSetProperty hook 已安装");
            } else {
                NSLog(@"[CPUthermal] 警告: 未找到 IOServiceSetProperty");
            }
        }

        void *monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor", RTLD_NOW | RTLD_GLOBAL);
        if (monitor) {
            void *getConfig = dlsym(monitor, "_getConfigurationFor");
            if (getConfig) {
                MSHookFunction(getConfig, (void *)new_getConfigurationFor, (void **)&orig_getConfigurationFor);
                NSLog(@"[CPUthermal] _getConfigurationFor hook 已安装");
            } else {
                NSLog(@"[CPUthermal] 未找到 _getConfigurationFor (非致命)");
            }
        } else {
            NSLog(@"[CPUthermal] 未找到 DeviceMonitor.framework (非致命)");
        }

        if (g_suppressTempPopup) {
            applySuppressTempPopup(YES);
        }

        NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:%d°C CPU:%d 亮度:%d 热状态:%d HID:%d CPMS:%d 低电模拟:%d 禁弹窗:%d",
              (int)(kSafetyTempThreshold / 1000),
              g_cpuProtection, g_brightnessProtection, g_thermalStateProtection,
              g_blockHidEvents, g_keepCPSMAlive,
              g_lowPowerSimulation, g_suppressTempPopup);

        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            CFNotificationCenterAddObserver(c, NULL, onSettingsChanged,
                (__bridge CFStringRef)S("com.huayuarc.CPUthermal/settingsChanged"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

            CFNotificationCenterAddObserver(c, NULL, onPuppetEvent,
                (__bridge CFStringRef)S("com.huayuarc.CPUthermal.puppet"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}
