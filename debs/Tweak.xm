#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/runtime.h>
#include <roothide.h>
#import <IOKit/IOKitLib.h>

// ============================================================================
// CPUthermal — 温控插件（完全版）
//
// 双防护层设计:
//   第1层 (IOKit): 拦截传感器温度读取、降频操作、属性写入、Darwin 通知广播
//   第2层 (ObjC):  钩住 thermalmonitord 内部类决策方法，阻止热缓解动作
//
// 集成自 Insulation (com.be-huge.insulation) v0.1.36 的增强功能:
//   - 功率模式: 低功耗(限制功率) / 满血(解除全部温控)
//   - 屏蔽高温通知
//   - ThermalManager 直接功率参数控制 (setCPULevel:/setCPUPowerCeiling: 等)
//
// 冲突避免原则:
//   - 传感器读数拦截只走 IOKit，不走 ObjC
//   - 所有新增 hook 有独立开关
//   - 保留紧急热保护安全阀 (75°C+ 不拦截)
//
// 注意: 禁止使用 @"" ObjC 字符串常量（roothide 重映射会破坏 __cfstring）
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================================

// 动态创建 NSString 的辅助宏 — 避免编译期 __cfstring
#define S(str) [NSString stringWithUTF8String:(str)]

// ============================================================================
// 功率模式枚举
// ============================================================================
typedef NS_ENUM(NSInteger, PowerMode) {
    PowerModeLowPower  = 0,  // 低功耗 — 主动限制功率
    PowerModeFullPower = 1,  // 满血 — 主动解除全部温控
};

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
// ↑ 已有
// ↓ 新增自 Insulation — 直接功率控制
- (void)setCPULevel:(int)level;
- (void)setCPULowPowerTarget:(double)target;
- (void)setCPUPowerCeiling:(double)ceiling fromDecisionSource:(id)source;
- (void)setCPUPowerFloor:(double)floor fromDecisionSource:(id)source;
- (void)setCPUPowerZoneTarget:(double)target;
- (void)setDVD1Level:(int)level;
- (void)setGPUPowerCeiling:(double)ceiling fromDecisionSource:(id)source;
- (void)setGPUPowerFloor:(double)floor fromDecisionSource:(id)source;
- (void)setGPUPowerZoneTarget:(double)target;
- (void)setMaxGraphicsDrivePowerTarget:(double)target;
- (void)setMaxPackagePower:(double)power;
- (void)setPackageLowPowerTarget;
- (void)setPackagePowerCeiling:(double)ceiling fromDecisionSource:(id)source;
- (void)setPackagePowerFloor:(double)floor fromDecisionSource:(id)source;
- (void)setPackagePowerZoneTarget;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setSGXLevel:(int)level;
- (void)setThermalState:(int)state;
- (double)getGPUTargetPower;
- (double)getPackageGPUPowerTarget;
- (double)getPackagePowerZoneMetric;
- (void)handleMCSThermalPressure;
- (void)initProduct:(id)product;
- (void)putDeviceInLowTempSimulationMode:(BOOL)mode;
- (void)putDeviceInThermalSimulationMode:(BOOL)mode;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)simulateLightThermalPressure;
- (void)thermalMitigation:(id)mitigation;
- (void)thermalPressure:(id)pressure;
- (id)thermalPressureLevel;
- (BOOL)thermalUpdatesToWatchdogEnabled:(BOOL)enabled;
- (void)tryTakeAction;
- (void)updateCPU;
- (void)updateGPU;
- (void)updatePackage;
- (void)updatePowerzoneTelemetry;
- (void)getConfigurationFor:(id)config;
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
// 配置 — 原 6 个开关 + 新增 2 个
// ============================================================================
static BOOL g_enabled               = YES; // 总开关（默认开启）
static BOOL g_cpuProtection         = YES; // CPU 性能保护(降频/决策树/控制力度/配置表)
static BOOL g_brightnessProtection  = YES; // 屏幕亮度保护(降亮度/背光配置)
static BOOL g_thermalStateProtection= YES; // 热状态封锁(Nominal/热压力/强制级别)
static BOOL g_blockHidEvents        = YES; // 阻止 HID 温度事件
static BOOL g_keepCPSMAlive         = NO;  // 保留 CPMS 紧急保护(安全阀) 默认关闭

// ★ 新增自 Insulation: 功率模式 + 屏蔽通知
static PowerMode g_powerMode               = PowerModeLowPower;  // 功率模式，默认低功耗
static BOOL      g_suppressThermalNotifications = NO;             // 屏蔽高温通知，默认关闭

// 低功耗 CPU 频率目标：1428MHz ~ 2016MHz
static const int kLowPowerCPUFreqMinMHz = 1428;
static const int kLowPowerCPUFreqMaxMHz = 2016;
static const int kLowPowerCPUFreqMinKHz = 1428000;
static const int kLowPowerCPUFreqMaxKHz = 2016000;
static const int64_t kLowPowerCPUFreqMinHz = 1428000000LL;
static const int64_t kLowPowerCPUFreqMaxHz = 2016000000LL;

// 低功耗主动下发限频时，临时放行本插件自己的降频写入
static volatile int g_applyingLowPowerMode = 0;

// 温度安全阀 — 超过此值不拦截任何保护
static const int64_t kSafetyTempThreshold = 75000;  // 75°C (毫摄氏度)

// 注意: 用 C 字符串而非 ObjC 常量，避免 roothide 重映射破坏 __cfstring
static const char *kPrefPathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";

static CommonProduct *g_commonProduct = nil;
static ThermalManager *g_thermalManager = nil;

static BOOL isTemperatureAboveSafetyCeiling(void);

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

        // ★ 读取功率模式 (默认 lowPower)
        NSString *modeStr = d[S("powerMode")] ?: S("lowPower");
        if ([modeStr isEqualToString:S("fullPower")]) {
            g_powerMode = PowerModeFullPower;
        } else {
            g_powerMode = PowerModeLowPower;
        }

        // ★ 读取屏蔽通知开关 (默认 NO)
        g_suppressThermalNotifications = [d[S("suppressThermalNotifications")] ?: [NSNumber numberWithBool:NO] boolValue];
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

static BOOL shouldBlockCPUMitigation(void) {
    if (!g_enabled) return NO;
    if (!g_cpuProtection) return NO;
    if (g_powerMode == PowerModeLowPower) return NO;
    if (g_applyingLowPowerMode > 0) return NO;
    return YES;
}

static BOOL shouldClampLowPowerCPU(void) {
    if (!g_enabled) return NO;
    if (!g_cpuProtection) return NO;
    if (g_powerMode != PowerModeLowPower) return NO;
    if (g_applyingLowPowerMode > 0) return NO;
    if (isTemperatureAboveSafetyCeiling()) return NO;
    return YES;
}

static BOOL keyLooksLikeCPUFrequency(NSString *key) {
    if (!key) return NO;
    return [key localizedCaseInsensitiveContainsString:S("freq")] ||
           [key localizedCaseInsensitiveContainsString:S("speed")] ||
           [key localizedCaseInsensitiveContainsString:S("clock")];
}

static BOOL keyLooksLikeCPUControl(NSString *key) {
    if (!key) return NO;
    return [key localizedCaseInsensitiveContainsString:S("cpu")] ||
           [key localizedCaseInsensitiveContainsString:S("freq")] ||
           [key localizedCaseInsensitiveContainsString:S("frequency")] ||
           [key localizedCaseInsensitiveContainsString:S("performance")] ||
           [key localizedCaseInsensitiveContainsString:S("throttle")] ||
           [key localizedCaseInsensitiveContainsString:S("mitigation")] ||
           [key localizedCaseInsensitiveContainsString:S("speed")] ||
           [key localizedCaseInsensitiveContainsString:S("limit")];
}

static CFTypeRef createLowPowerFrequencyValueForKey(NSString *key) {
    if ([key localizedCaseInsensitiveContainsString:S("min")]) {
        int minMHz = kLowPowerCPUFreqMinMHz;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &minMHz);
    }

    int maxMHz = kLowPowerCPUFreqMaxMHz;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxMHz);
}

static CFTypeRef createClampedLowPowerFrequencyValue(CFTypeRef value, NSString *key) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return createLowPowerFrequencyValueForKey(key);
    }

    int64_t number = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number)) {
        return createLowPowerFrequencyValueForKey(key);
    }

    int64_t minValue = kLowPowerCPUFreqMinMHz;
    int64_t maxValue = kLowPowerCPUFreqMaxMHz;
    if (number >= 100000000) {
        minValue = kLowPowerCPUFreqMinHz;
        maxValue = kLowPowerCPUFreqMaxHz;
    } else if (number >= 100000) {
        minValue = kLowPowerCPUFreqMinKHz;
        maxValue = kLowPowerCPUFreqMaxKHz;
    }

    int64_t clamped = number;
    if ([key localizedCaseInsensitiveContainsString:S("min")]) {
        clamped = minValue;
    } else if (clamped < minValue) {
        clamped = minValue;
    } else if (clamped > maxValue) {
        clamped = maxValue;
    }

    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &clamped);
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
                output[i] = 36000;  // 36°C — 永远显示正常温度
            }
        }
        return KERN_SUCCESS;
    }
    if (shouldBlockCPUMitigation() && SELECTOR_IS_MITIGATION(selector)) {
        return KERN_SUCCESS;
    }
    return %orig;
}

// --- IOServiceSetProperty — 阻止写降频/降亮度属性 ---
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (!g_enabled) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    // 安全阀: 超过阈值不拦截
    if (isTemperatureAboveSafetyCeiling()) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    NSString *ks = (__bridge NSString *)key;
    if (g_cpuProtection && keyLooksLikeCPUControl(ks)) {
        if (g_powerMode == PowerModeLowPower) {
            if (keyLooksLikeCPUFrequency(ks)) {
                CFTypeRef clampedValue = createClampedLowPowerFrequencyValue(value, ks);
                kern_return_t ret = orig_IOServiceSetProperty(service, key, clampedValue);
                CFRelease(clampedValue);
                return ret;
            }

            return orig_IOServiceSetProperty(service, key, value);
        }

        if (shouldBlockCPUMitigation()) return KERN_SUCCESS;
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
    if (!g_enabled || !g_thermalStateProtection) return %orig;

    // 安全阀
    if (isTemperatureAboveSafetyCeiling()) return %orig;

    NSString *ks = (__bridge NSString *)key;
    if ([ks localizedCaseInsensitiveContainsString:S("temperature")] ||
        [ks localizedCaseInsensitiveContainsString:S("thermal-level")] ||
        [ks localizedCaseInsensitiveContainsString:S("hot-level")] ||
        [ks localizedCaseInsensitiveContainsString:S("thermalstate")]) {
        int zero = 0;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
    }
    if (keyLooksLikeCPUFrequency(ks)) {
        if (g_powerMode == PowerModeLowPower) {
            return createLowPowerFrequencyValueForKey(ks);
        }
        int max = INT_MAX;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &max);
    }
    if ([ks localizedCaseInsensitiveContainsString:S("brightness")] ||
        [ks localizedCaseInsensitiveContainsString:S("backlight")]) {
        float one = 1.0;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &one);
    }
    return %orig;
}

// ============================================================================
// ★ 新增: notify_post 全面拦截 — 屏蔽高温通知
// ============================================================================
%hookf(uint32_t, notify_post, const char *name) {
    // 总开关关闭 => 不拦截
    if (!g_enabled) {
        return %orig;
    }

    // 安全阀: 超过阈值不拦截通知
    if (isTemperatureAboveSafetyCeiling()) {
        return %orig;
    }

    NSString *ns = [NSString stringWithUTF8String:name];

    // 【原有】thermalStateProtection 拦截 thermalstate 通知
    if (g_thermalStateProtection) {
        if ([ns containsString:S("thermalstate")] ||
            ([ns containsString:S("thermal")] && [ns containsString:S("high")])) {
            return NOTIFY_STATUS_OK;
        }
    }

    // ★ 新增: 屏蔽高温通知 — 拦截所有 thermal 相关通知
    if (g_suppressThermalNotifications) {
        if ([ns containsString:S("thermal")] ||
            [ns containsString:S("Thermal")] ||
            [ns containsString:S("temperature")] ||
            [ns containsString:S("kOSThermalNotification")] ||
            [ns containsString:S("OSThermalStatus")]) {
            return NOTIFY_STATUS_OK;
        }
    }

    return %orig;
}

// ============================================================================
// ★ 新增自 Insulation: 直接功率参数控制
// ============================================================================

static void applyFullPowerMode(ThermalManager *manager) {
    // === 满血模式：解除全部温控，设最大功率 ===
    NSLog(@"[CPUthermal] ★ 应用满血模式 — 解除全部温控");

    // CPU: 无级别限制, 功率拉到最高
    [manager setCPULevel:0];
    [manager setCPUPowerCeiling:100000.0 fromDecisionSource:S("CPUthermal")];
    [manager setCPUPowerFloor:0 fromDecisionSource:S("CPUthermal")];
    [manager setCPUPowerZoneTarget:15000.0];
    [manager setCPULowPowerTarget:15000.0];

    // DVD1: 无限制
    [manager setDVD1Level:0];

    // GPU: 无限制
    [manager setGPUPowerCeiling:100000.0 fromDecisionSource:S("CPUthermal")];
    [manager setGPUPowerFloor:0 fromDecisionSource:S("CPUthermal")];
    [manager setGPUPowerZoneTarget:25000.0];
    [manager setMaxGraphicsDrivePowerTarget:25000.0];

    // Package: 无限制
    [manager setMaxPackagePower:100000.0];
    [manager setPackagePowerCeiling:100000.0 fromDecisionSource:S("CPUthermal")];
    [manager setPackagePowerFloor:0 fromDecisionSource:S("CPUthermal")];
    [manager setPackagePowerZoneTarget];

    // SGX: 无限制
    [manager setSGXLevel:0];

    // 禁用省电/缓解
    [manager setPowerSaveActive:NO];
    [manager setCPMSMitigationsEnabled:NO];
    [manager setThermalState:0];

    // 提交更新
    [manager updateCPU];
    [manager updateGPU];
    [manager updatePackage];
}

static void applyLowPowerMode(ThermalManager *manager) {
    // === 低功耗模式：限制功率，但不降亮度 ===
    NSLog(@"[CPUthermal] ★ 应用低功耗模式 — CPU 限频 %d~%dMHz，限制功率，保持亮度",
          kLowPowerCPUFreqMinMHz, kLowPowerCPUFreqMaxMHz);

    g_applyingLowPowerMode++;
    @try {
        // CPU: 主动进入限频档，目标限制在 1428MHz ~ 2016MHz
        [manager setCPULevel:80];
        [manager setCPUPowerCeiling:(double)kLowPowerCPUFreqMaxMHz fromDecisionSource:S("CPUthermal")];
        [manager setCPUPowerFloor:(double)kLowPowerCPUFreqMinMHz fromDecisionSource:S("CPUthermal")];
        [manager setCPUPowerZoneTarget:(double)kLowPowerCPUFreqMaxMHz];
        [manager setCPULowPowerTarget:(double)kLowPowerCPUFreqMaxMHz];
        [manager setDVD1Level:1];

        // GPU/Package: 同步压低功率，达到省电效果
        [manager setGPUPowerCeiling:5000.0 fromDecisionSource:S("CPUthermal")];
        [manager setGPUPowerFloor:0 fromDecisionSource:S("CPUthermal")];
        [manager setMaxPackagePower:8000.0];
        [manager setPackagePowerCeiling:8000.0 fromDecisionSource:S("CPUthermal")];
        [manager setPackagePowerFloor:0 fromDecisionSource:S("CPUthermal")];

        // 不调用 setPowerSaveActive:YES，避免系统顺带降亮度
        [manager setPowerSaveActive:NO];
        if (g_brightnessProtection) {
            [manager setMaxGraphicsDrivePowerTarget:25000.0];
        }

        [manager updateCPU];
        [manager updateGPU];
        [manager updatePackage];
    } @finally {
        g_applyingLowPowerMode--;
    }
}

// ============================================================================
// ★ 新增自 Insulation: 执行功率模式
// ============================================================================
static void applyPowerMode(void) {
    if (!g_enabled) return;

    // 安全阀检查
    if (isTemperatureAboveSafetyCeiling()) {
        NSLog(@"[CPUthermal] 温度超过安全阀 (75°C)，跳过功率模式应用");
        return;
    }

    ThermalManager *manager = g_thermalManager;
    if (!manager) {
        Class cls = objc_getClass("ThermalManager");
        if (cls && [cls respondsToSelector:NSSelectorFromString(S("sharedInstance"))]) {
            manager = [cls valueForKey:S("sharedInstance")];
        }
    }
    if (!manager) {
        NSLog(@"[CPUthermal] 警告: 无法获取 ThermalManager 实例");
        return;
    }

    switch (g_powerMode) {
        case PowerModeFullPower:
            applyFullPowerMode(manager);
            break;
        case PowerModeLowPower:
        default:
            applyLowPowerMode(manager);
            break;
    }
}

// ============================================================================
// ObjC 类钩子（第1层: CommonProduct / HidSensors — 已有）
// ============================================================================

// --- CommonProduct: thermalmonitord 核心热管理对象 ---
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
    if (shouldBlockCPUMitigation()) {
        return;
    }
    %orig;
}

- (void)simulateLightThermalPressure {
    if (shouldBlockCPUMitigation()) {
        return;
    }
    %orig;
}

- (void)updatePowerzoneTelemetry {
    if (shouldBlockCPUMitigation()) {
        return;
    }
    %orig;
}

%end

// --- HidSensors: HID 温度事件处理 ---
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

- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table {
    id res = %orig(components, hotspots, table);
    if (res) {
        g_thermalManager = res;
        if (g_enabled) {
            applyPowerMode();
        }
    }
    return res;
}

- (void)initProduct:(id)product {
    g_thermalManager = self;
    %orig(product);
    if (g_enabled) {
        applyPowerMode();
    }
}

- (void)setCPULevel:(int)level {
    if (shouldClampLowPowerCPU()) {
        %orig(80);
        return;
    }
    %orig(level);
}

- (void)setCPUPowerCeiling:(double)ceiling fromDecisionSource:(id)source {
    if (shouldClampLowPowerCPU() && ceiling > (double)kLowPowerCPUFreqMaxMHz) {
        %orig((double)kLowPowerCPUFreqMaxMHz, S("CPUthermal"));
        return;
    }
    %orig(ceiling, source);
}

- (void)setCPUPowerFloor:(double)floor fromDecisionSource:(id)source {
    if (shouldClampLowPowerCPU()) {
        double clampedFloor = floor;
        if (clampedFloor < (double)kLowPowerCPUFreqMinMHz || clampedFloor > (double)kLowPowerCPUFreqMaxMHz) {
            clampedFloor = (double)kLowPowerCPUFreqMinMHz;
        }
        %orig(clampedFloor, S("CPUthermal"));
        return;
    }
    %orig(floor, source);
}

- (void)setCPUPowerZoneTarget:(double)target {
    if (shouldClampLowPowerCPU() && target > (double)kLowPowerCPUFreqMaxMHz) {
        %orig((double)kLowPowerCPUFreqMaxMHz);
        return;
    }
    %orig(target);
}

- (void)setCPULowPowerTarget:(double)target {
    if (shouldClampLowPowerCPU() && target > (double)kLowPowerCPUFreqMaxMHz) {
        %orig((double)kLowPowerCPUFreqMaxMHz);
        return;
    }
    %orig(target);
}

// 决策树评估
- (void)evaluateDecisionTree {
    if (shouldBlockCPUMitigation()) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
            return;
        }
    }
    %orig;
}

// 热压力升级通知
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force {
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            %orig(notification, NO);
            return;
        }
    }

    // ★ 新增: 屏蔽高温通知 — ObjC 层彻底阻断
    if (g_enabled && g_suppressThermalNotifications) {
        // force 参数改为 NO，持续压制热压力通知
        %orig(notification, NO);
        return;
    }

    %orig;
}

// ★ 增强: 热通知 — 勾住并阻断（通知屏蔽 + 热状态封锁）
- (void)updateThermalNotification:(id)notification {
    // 屏蔽高温通知优先 — 完全阻断所有热通知
    if (g_enabled && g_suppressThermalNotifications) {
        return;
    }

    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            return;
        }
    }
    %orig;
}

// ★ 新增: 热压力级别 — 通知屏蔽时强制返回 nominal
- (id)thermalPressureLevel {
    if (g_enabled && g_suppressThermalNotifications) {
        return S("nominal");
    }
    return %orig;
}

- (BOOL)shouldEnforceLightThermalPressure {
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            return NO;
        }
    }
    return %orig;
}

- (float)getReleaseRateForComponent:(id)component {
    if (shouldBlockCPUMitigation()) {
        if (!isTemperatureAboveSafetyCeiling()) {
            float rate = %orig(component);
            if (rate > 0.5) {
                rate = rate * 0.5;
            }
            return rate;
        }
    }
    return %orig(component);
}

- (int)getPotentialForcedThermalLevel:(id)component {
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            return 0;
        }
    }
    return %orig(component);
}

- (int)getPotentialForcedThermalPressureLevel {
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            return 0;
        }
    }
    return %orig;
}

- (id)getBatteryServiceSuggestion:(id)suggestion {
    id result = %orig(suggestion);
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            return nil;
        }
    }
    return result;
}

%end

// --- ThermalControl: hook 控制力度计算 ---
%hook ThermalControl

- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
    if (shouldBlockCPUMitigation()) {
        if (!isTemperatureAboveSafetyCeiling()) {
            float effort = %orig(trigger, arg2);
            float newEffort = effort * 0.5;
            if (newEffort < 0 && effort > 0) newEffort = 0;
            return newEffort;
        }
    }
    return %orig(trigger, arg2);
}

- (void)actionComponentControl {
    if (shouldBlockCPUMitigation()) {
        if (!isTemperatureAboveSafetyCeiling()) {
            return;
        }
    }
    %orig;
}

- (void)readReleaseRateForAllComponents {
    if (shouldBlockCPUMitigation()) {
        if (!isTemperatureAboveSafetyCeiling()) {
            return;
        }
    }
    %orig;
}

%end

// ============================================================================
// C 函数钩子: _getConfigurationFor → ___New_getConfigurationFor___
// ============================================================================

static NSDictionary* (*orig_getConfigurationFor)(NSString *key) = NULL;

static NSDictionary* new_getConfigurationFor(NSString *key) {
    NSDictionary *config = orig_getConfigurationFor(key);
    if (!shouldBlockCPUMitigation() || !config) return config;

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

// --- NSDictionary: 拦截 thermal plist 加载并修补 ---
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
                    return patched;
                }
            }
        }
    }
    return res;
}

%end

// ============================================================================
// Puppet 事件 + ★ 功率模式应用
// ============================================================================
static void executePuppetEvent(void) {
    if (!g_commonProduct) return;
    @autoreleasepool {
        // 1) 重新加载配置（可能来自设置面板的变更）
        loadPrefs();

        // 2) 应用功率模式
        applyPowerMode();

        // 3) 执行原有的 thermal simulation
        NSString *path = [NSString stringWithUTF8String:jbroot(kPrefPathC)];
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
        NSString *level = prefs[S("thermalPuppetValue")] ?: S("nominal");
        [g_commonProduct putDeviceInThermalSimulationMode:level];
        NSLog(@"[CPUthermal] Puppet 事件: 热模式=%@ 功率模式=%ld 屏蔽通知=%d",
              level, (long)g_powerMode, g_suppressThermalNotifications);
    }
}

static void onPuppetEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    executePuppetEvent();
}

// ============================================================================
// ★ 新增: 监听功率模式变更通知（从设置面板/CC 模块触发）
// ============================================================================
static void onPowerModeChanged(CFNotificationCenterRef center, void *observer,
    CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        loadPrefs();
        applyPowerMode();
        NSLog(@"[CPUthermal] 功率模式已变更: %ld 屏蔽通知=%d",
              (long)g_powerMode, g_suppressThermalNotifications);
    }
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

        // 确保 IOKit 已加载
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (iokit) {
            kern_return_t (*ptr)(io_service_t, CFStringRef, CFTypeRef) =
                (kern_return_t (*)(io_service_t, CFStringRef, CFTypeRef))
                dlsym(iokit, "IOServiceSetProperty");
            if (ptr) {
                MSHookFunction((void *)ptr, (void *)hooked_IOServiceSetProperty,
                    (void **)&orig_IOServiceSetProperty);
                NSLog(@"[CPUthermal] IOServiceSetProperty hook 已安装");
            }
        }

        // _getConfigurationFor — C 函数钩子
        void *monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor",
            RTLD_NOW | RTLD_GLOBAL);
        if (monitor) {
            void *getConfig = dlsym(monitor, "_getConfigurationFor");
            if (getConfig) {
                MSHookFunction(getConfig, (void *)new_getConfigurationFor,
                    (void **)&orig_getConfigurationFor);
                NSLog(@"[CPUthermal] _getConfigurationFor hook 已安装");
            }
        }

        // ★ 注册功率模式变更监听（兼容 Insulation 通知名）
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            // 原有的 puppet 事件
            CFNotificationCenterAddObserver(c, NULL, onPuppetEvent,
                (__bridge CFStringRef)S("com.huayuarc.CPUthermal.puppet"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

            // 新增: 功率模式变更通知（从设置面板发出）
            CFNotificationCenterAddObserver(c, NULL, onPowerModeChanged,
                (__bridge CFStringRef)S("com.huayuarc.CPUthermal/powerModeChanged"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        // ★ 开机延迟 2s 应用功率模式（确保 ThermalManager 已初始化）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            applyPowerMode();
        });

        NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:%d°C CPU:%d 亮度:%d 热状态:%d HID:%d CPMS:%d 功率模式:%ld 屏蔽通知:%d",
              (int)(kSafetyTempThreshold / 1000),
              g_cpuProtection, g_brightnessProtection, g_thermalStateProtection,
              g_blockHidEvents, g_keepCPSMAlive,
              (long)g_powerMode, g_suppressThermalNotifications);
    }
}
