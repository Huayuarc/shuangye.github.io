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
- (void)putDeviceInLowTempSimulationMode:(id)arg1;
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
- (void)setMaxCPUPowerTarget:(double)target useLegacyPath:(BOOL)legacy setProperty:(BOOL)setProperty;
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
- (void)putDeviceInLowTempSimulationMode:(id)mode;
- (void)putDeviceInThermalSimulationMode:(id)mode;
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

@interface MitigationController : NSObject
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)setCPULevel:(int)level;
- (void)setCPULowPowerTarget:(int)target;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(int)source;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(int)source;
- (void)setCPUPowerZoneTarget:(int)target;
- (void)setDVD1Level:(int)level;
- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(int)source;
- (void)setGPUPowerFloor:(int)floor fromDecisionSource:(int)source;
- (void)setGPUPowerZoneTarget:(int)target;
- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(CFStringRef)property;
- (void)setMaxGraphicsDrivePowerTarget:(int)target;
- (void)setMaxPackagePower:(int)power;
- (void)setPackageLowPowerTarget;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(int)source;
- (void)setPackagePowerFloor:(int)floor fromDecisionSource:(int)source;
- (void)setPackagePowerZoneTarget;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(int)token;
- (void)setSGXLevel:(int)level;
- (void)updateCPU;
- (void)updateGPU;
- (void)updatePackage;
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

// 低功耗 CPU 频率目标：大小核都尽量锁定在 2016MHz 左右。
// 注意：不能再使用真正的系统低功耗等级/PowerSaveToken，实测会把 PCPU 大核压到 1380MHz。
static const int kLowPowerCPUFreqMHz = 2016;
static const int64_t kLowPowerCPUFreqKHz = 2016000LL;
static const int64_t kLowPowerCPUFreqHz = 2016000000LL;
static const int kLowPowerCPULevel = 80;

static int lowPowerCPUFreqTargetMHz(void) {
    return kLowPowerCPUFreqMHz;
}

static int lowPowerCPUFreqTargetKHz(void) {
    return (int)kLowPowerCPUFreqKHz;
}

static int64_t lowPowerCPUFreqTargetHz(void) {
    return kLowPowerCPUFreqHz;
}

static double lowPowerCPUPowerMax(void) {
    return (double)kLowPowerCPUFreqMHz;
}

static double lowPowerPackagePowerMax(void) {
    return (double)kLowPowerCPUFreqMHz;
}

static int lowPowerCPUPowerFloor(void) {
    return kLowPowerCPUFreqMHz;
}

static int lowPowerPowerSaveToken(void) {
    return 0;
}

static BOOL lowPowerPowerSaveActive(void) {
    return NO;
}

// 低功耗主动下发限频时，临时放行本插件自己的降频写入
static volatile int g_applyingLowPowerMode = 0;
static dispatch_source_t g_lowPowerReapplyTimer = NULL;

// 温度安全阀 — 超过此值不拦截任何保护
static const int64_t kSafetyTempThreshold = 75000;  // 75°C (毫摄氏度)

// 注意: 用 C 字符串而非 ObjC 常量，避免 roothide 重映射破坏 __cfstring
static const char *kPrefPathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";

static CommonProduct *g_commonProduct = nil;
static ThermalManager *g_thermalManager = nil;
static MitigationController *g_mitigationController = nil;
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static BOOL isTemperatureAboveSafetyCeiling(void);

static NSDictionary *loadPrefsDictionary(void) {
    NSString *rootfsPath = S(kPrefPathC);
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:rootfsPath];
    if (prefs) return prefs;

    NSString *jbPath = [NSString stringWithUTF8String:jbroot(kPrefPathC)];
    if (![jbPath isEqualToString:rootfsPath]) {
        prefs = [NSDictionary dictionaryWithContentsOfFile:jbPath];
    }
    return prefs;
}

static void loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = loadPrefsDictionary();
        if (!d) return;
        g_enabled               = [d[S("enabled")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_cpuProtection         = [d[S("cpuProtection")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_brightnessProtection  = [d[S("brightnessProtection")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_thermalStateProtection= [d[S("thermalStateProtection")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_blockHidEvents        = [d[S("blockHidEvents")] ?: [NSNumber numberWithBool:YES] boolValue];
        g_keepCPSMAlive         = [d[S("keepCPMSAlive")] ?: [NSNumber numberWithBool:NO] boolValue];

        // ★ 读取功率模式 (默认 lowPower2016；旧 lowPower/低频档统一迁移为 2016)
        id modeValue = d[S("powerMode")];
        NSString *modeStr = [modeValue isKindOfClass:[NSString class]] ? modeValue : S("lowPower2016");
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

static BOOL keyLooksLikeLowPowerBoolean(NSString *key) {
    if (!key) return NO;
    return [key localizedCaseInsensitiveContainsString:S("powersave")] ||
           [key localizedCaseInsensitiveContainsString:S("power-save")] ||
           [key localizedCaseInsensitiveContainsString:S("lowpowermode")];
}

static BOOL keyLooksLikePowerSaveToken(NSString *key) {
    if (!key) return NO;
    return [key localizedCaseInsensitiveContainsString:S("powersavetoken")] ||
           ([key localizedCaseInsensitiveContainsString:S("powersave")] &&
            [key localizedCaseInsensitiveContainsString:S("token")]);
}

static BOOL keyLooksLikeCPUPowerLimit(NSString *key) {
    if (!key) return NO;
    BOOL cpuOrPackage = [key localizedCaseInsensitiveContainsString:S("cpu")] ||
                        [key localizedCaseInsensitiveContainsString:S("package")];
    if (!cpuOrPackage) return NO;
    return [key localizedCaseInsensitiveContainsString:S("power")] ||
           [key localizedCaseInsensitiveContainsString:S("target")] ||
           [key localizedCaseInsensitiveContainsString:S("ceiling")];
}

static CFTypeRef createLowPowerFrequencyValueForKey(NSString *key) {
    int64_t targetValue = lowPowerCPUFreqTargetMHz();
    if (key) {
        if ([key localizedCaseInsensitiveContainsString:S("khz")]) {
            targetValue = lowPowerCPUFreqTargetKHz();
        } else if ([key localizedCaseInsensitiveContainsString:S("mhz")]) {
            targetValue = lowPowerCPUFreqTargetMHz();
        } else if ([key localizedCaseInsensitiveContainsString:S("hz")]) {
            targetValue = lowPowerCPUFreqTargetHz();
        }
    }
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &targetValue);
}

static CFTypeRef createClampedLowPowerFrequencyValue(CFTypeRef value, NSString *key) {
    (void)key;
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return createLowPowerFrequencyValueForKey(key);
    }

    int64_t number = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number)) {
        return createLowPowerFrequencyValueForKey(key);
    }

    int64_t targetValue = lowPowerCPUFreqTargetMHz();
    if (number >= 100000000) {
        targetValue = lowPowerCPUFreqTargetHz();
    } else if (number >= 100000) {
        targetValue = lowPowerCPUFreqTargetKHz();
    }

    int64_t clamped = targetValue;

    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &clamped);
}

static CFTypeRef createLowPowerPowerValueForKey(NSString *key) {
    double target = lowPowerCPUPowerMax();
    if ([key localizedCaseInsensitiveContainsString:S("package")]) {
        target = lowPowerPackagePowerMax();
    } else if ([key localizedCaseInsensitiveContainsString:S("target")]) {
        target = (double)lowPowerCPUFreqTargetMHz();
    }
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &target);
}

static void setNumberProperty(io_service_t service, const char *key, int64_t value, CFNumberType type) {
    if (!service || !key || !orig_IOServiceSetProperty) return;
    CFStringRef cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!cfKey) return;

    CFNumberRef number = NULL;
    if (type == kCFNumberIntType) {
        int intValue = (int)value;
        number = CFNumberCreate(kCFAllocatorDefault, type, &intValue);
    } else {
        number = CFNumberCreate(kCFAllocatorDefault, type, &value);
    }
    if (number) {
        orig_IOServiceSetProperty(service, cfKey, number);
        CFRelease(number);
    }
    CFRelease(cfKey);
}

static void setDoubleProperty(io_service_t service, const char *key, double value) {
    if (!service || !key || !orig_IOServiceSetProperty) return;
    CFStringRef cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!cfKey) return;
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
    if (number) {
        orig_IOServiceSetProperty(service, cfKey, number);
        CFRelease(number);
    }
    CFRelease(cfKey);
}

static void setBoolProperty(io_service_t service, const char *key, BOOL value) {
    if (!service || !key || !orig_IOServiceSetProperty) return;
    CFStringRef cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!cfKey) return;
    orig_IOServiceSetProperty(service, cfKey, value ? kCFBooleanTrue : kCFBooleanFalse);
    CFRelease(cfKey);
}

static void setLowPowerPPMPropertiesOnService(io_service_t service) {
    if (!service || !orig_IOServiceSetProperty) return;

    setBoolProperty(service, "PowerSave", NO);
    setBoolProperty(service, "powerSaveActive", NO);
    setBoolProperty(service, "PowerSaveActive", NO);
    setNumberProperty(service, "powerSaveToken", lowPowerPowerSaveToken(), kCFNumberIntType);
    setNumberProperty(service, "PowerSaveToken", lowPowerPowerSaveToken(), kCFNumberIntType);
    setNumberProperty(service, "CPULevel", kLowPowerCPULevel, kCFNumberIntType);
    setNumberProperty(service, "CPUPerformanceLevel", kLowPowerCPULevel, kCFNumberIntType);
    setDoubleProperty(service, "CPUMaxPower", lowPowerCPUPowerMax());
    setDoubleProperty(service, "CPUPowerTarget", (double)lowPowerCPUFreqTargetMHz());
    setDoubleProperty(service, "CPULowPowerTarget", (double)lowPowerCPUFreqTargetMHz());
    setDoubleProperty(service, "PackageLowPowerTarget", lowPowerPackagePowerMax());
    setDoubleProperty(service, "MaxCPUPowerTarget", lowPowerCPUPowerMax());
    setDoubleProperty(service, "PackagePowerTarget", lowPowerPackagePowerMax());
}

static void setLowPowerFrequencyPropertiesOnService(io_service_t service) {
    if (!service || !orig_IOServiceSetProperty) return;

    const char *minKeys[] = {
        "cpu-min-frequency", "cpu-min-freq", "cpu-frequency-min", "cpu-freq-min",
        "CPUFrequencyMin", "CPUFreqMin", "min-frequency", "min-freq",
        "cpu-frequency", "cpu-freq", "CPUFrequency", "CPUFreq",
        "pcpu-min-frequency", "pcpu-min-freq", "pcpu-frequency-min", "pcpu-freq-min",
        "PCPUFrequencyMin", "PCPUFreqMin", "PCPUMinFrequency", "PCPUMinFreq",
        "ecpu-min-frequency", "ecpu-min-freq", "ecpu-frequency-min", "ecpu-freq-min",
        "ECPUFrequencyMin", "ECPUFreqMin", "ECPUMinFrequency", "ECPUMinFreq",
        NULL
    };
    const char *maxKeys[] = {
        "cpu-max-frequency", "cpu-max-freq", "cpu-frequency-max", "cpu-freq-max",
        "CPUFrequencyMax", "CPUFreqMax", "max-frequency", "max-freq",
        "cpu-frequency-limit", "cpu-freq-limit", "CPUFrequencyLimit", "CPUFreqLimit",
        "cpu-cluster-frequency", "cpu-cluster-freq", "CPUClusterFrequency", "CPUClusterFreq",
        "pcpu-max-frequency", "pcpu-max-freq", "pcpu-frequency-max", "pcpu-freq-max",
        "PCPUFrequencyMax", "PCPUFreqMax", "PCPUMaxFrequency", "PCPUMaxFreq",
        "pcpu-frequency", "pcpu-freq", "PCPUFrequency", "PCPUFreq",
        "pcpu-frequency-limit", "pcpu-freq-limit", "PCPUFrequencyLimit", "PCPUFreqLimit",
        "pcpu-cluster-frequency", "pcpu-cluster-freq", "PCPUClusterFrequency", "PCPUClusterFreq",
        "ecpu-max-frequency", "ecpu-max-freq", "ecpu-frequency-max", "ecpu-freq-max",
        "ECPUFrequencyMax", "ECPUFreqMax", "ECPUMaxFrequency", "ECPUMaxFreq",
        "ecpu-frequency", "ecpu-freq", "ECPUFrequency", "ECPUFreq",
        "ecpu-frequency-limit", "ecpu-freq-limit", "ECPUFrequencyLimit", "ECPUFreqLimit",
        "ecpu-cluster-frequency", "ecpu-cluster-freq", "ECPUClusterFrequency", "ECPUClusterFreq",
        NULL
    };
    CFNumberType types[] = {
        kCFNumberIntType,
        kCFNumberSInt64Type,
        kCFNumberSInt64Type
    };
    int64_t minValues[] = {
        lowPowerCPUFreqTargetMHz(),
        lowPowerCPUFreqTargetKHz(),
        lowPowerCPUFreqTargetHz()
    };
    int64_t maxValues[] = {
        lowPowerCPUFreqTargetMHz(),
        lowPowerCPUFreqTargetKHz(),
        lowPowerCPUFreqTargetHz()
    };

    for (int keyIndex = 0; minKeys[keyIndex]; keyIndex++) {
        for (int typeIndex = 0; typeIndex < 3; typeIndex++) {
            setNumberProperty(service, minKeys[keyIndex], minValues[typeIndex], types[typeIndex]);
        }
    }
    for (int keyIndex = 0; maxKeys[keyIndex]; keyIndex++) {
        for (int typeIndex = 0; typeIndex < 3; typeIndex++) {
            setNumberProperty(service, maxKeys[keyIndex], maxValues[typeIndex], types[typeIndex]);
        }
    }
}

static void applyLowPowerFrequencyProperties(void) {
    if (!orig_IOServiceSetProperty || !g_enabled || !g_cpuProtection || g_powerMode != PowerModeLowPower) return;
    if (isTemperatureAboveSafetyCeiling()) return;

    const char *serviceNames[] = {
        "ApplePMGR", "AppleARMPlatform", "ApplePPM", "ApplePPMCPU",
        "ApplePPMCPMS", "ApplePMGRNub", "AppleCLPC", "AppleT8110PMGR",
        "ApplePPMEntityCLPC", "AppleARMPMU", "AppleARMCPU", "AppleCPU", NULL
    };
    for (int i = 0; serviceNames[i]; i++) {
        CFMutableDictionaryRef matching = IOServiceMatching(serviceNames[i]);
        if (!matching) continue;
        io_iterator_t iterator = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) != KERN_SUCCESS) {
            continue;
        }
        io_service_t service;
        while ((service = IOIteratorNext(iterator))) {
            setLowPowerPPMPropertiesOnService(service);
            setLowPowerFrequencyPropertiesOnService(service);
            IOObjectRelease(service);
        }
        IOObjectRelease(iterator);
    }
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
static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (!g_enabled) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    // 安全阀: 超过阈值不拦截
    if (isTemperatureAboveSafetyCeiling()) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    NSString *ks = (__bridge NSString *)key;
    if (g_powerMode == PowerModeLowPower && keyLooksLikePowerSaveToken(ks)) {
        int token = lowPowerPowerSaveToken();
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &token);
        if (!number) return orig_IOServiceSetProperty(service, key, value);
        kern_return_t ret = orig_IOServiceSetProperty(service, key, number);
        CFRelease(number);
        return ret;
    }
    if (g_powerMode == PowerModeLowPower && keyLooksLikeLowPowerBoolean(ks)) {
        return orig_IOServiceSetProperty(service, key, kCFBooleanFalse);
    }
    if (g_cpuProtection && keyLooksLikeCPUControl(ks)) {
        if (g_powerMode == PowerModeLowPower) {
            if (keyLooksLikeCPUFrequency(ks)) {
                CFTypeRef clampedValue = createClampedLowPowerFrequencyValue(value, ks);
                kern_return_t ret = orig_IOServiceSetProperty(service, key, clampedValue);
                CFRelease(clampedValue);
                return ret;
            }
            if (keyLooksLikeCPUPowerLimit(ks)) {
                CFTypeRef clampedValue = createLowPowerPowerValueForKey(ks);
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

static MitigationController *activeMitigationController(void) {
    return g_mitigationController;
}

static void applyFullPowerToMitigationController(MitigationController *controller) {
    if (!controller) return;

    @try {
        [controller setCPULevel:0];
        [controller setCPUPowerCeiling:100000 fromDecisionSource:0];
        [controller setCPUPowerFloor:0 fromDecisionSource:0];
        [controller setCPUPowerZoneTarget:100000];
        [controller setCPULowPowerTarget:100000];
        [controller setMaxCPUPowerTarget:100000 useLegacyPath:YES setProperty:(__bridge CFStringRef)S("CPUthermal")];
        [controller setDVD1Level:0];

        [controller setGPUPowerCeiling:100000 fromDecisionSource:0];
        [controller setGPUPowerFloor:0 fromDecisionSource:0];
        [controller setGPUPowerZoneTarget:100000];
        [controller setMaxGraphicsDrivePowerTarget:100000];

        [controller setMaxPackagePower:100000];
        [controller setPackagePowerCeiling:100000 fromDecisionSource:0];
        [controller setPackagePowerFloor:0 fromDecisionSource:0];
        [controller setPackagePowerZoneTarget];

        [controller setSGXLevel:0];
        [controller setPowerSaveToken:0];
        [controller setPowerSaveActive:NO];
        [controller setCPMSMitigationsEnabled:NO];

        [controller updateCPU];
        [controller updateGPU];
        [controller updatePackage];
    } @catch (NSException *exception) {
        NSLog(S("[CPUthermal] MitigationController 满血下发异常: %@"), exception);
    }
}

static void applyLowPowerToMitigationController(MitigationController *controller) {
    if (!controller) return;

    g_applyingLowPowerMode++;
    @try {
        int cpuTarget = lowPowerCPUFreqTargetMHz();
        int packageTarget = (int)lowPowerPackagePowerMax();

        [controller setPowerSaveToken:lowPowerPowerSaveToken()];
        [controller setPowerSaveActive:lowPowerPowerSaveActive()];
        [controller setCPMSMitigationsEnabled:YES];

        [controller setCPULevel:kLowPowerCPULevel];
        [controller setCPUPowerCeiling:cpuTarget fromDecisionSource:0];
        [controller setCPUPowerFloor:lowPowerCPUPowerFloor() fromDecisionSource:0];
        [controller setCPUPowerZoneTarget:cpuTarget];
        [controller setMaxCPUPowerTarget:cpuTarget useLegacyPath:YES setProperty:(__bridge CFStringRef)S("CPUthermal")];
        [controller setCPULowPowerTarget:cpuTarget];
        [controller setDVD1Level:0];

        [controller setGPUPowerCeiling:cpuTarget fromDecisionSource:0];
        [controller setGPUPowerFloor:0 fromDecisionSource:0];
        [controller setMaxPackagePower:packageTarget];
        [controller setPackagePowerCeiling:packageTarget fromDecisionSource:0];
        [controller setPackagePowerFloor:lowPowerCPUPowerFloor() fromDecisionSource:0];
        [controller setPackageLowPowerTarget];

        if (g_brightnessProtection) {
            [controller setMaxGraphicsDrivePowerTarget:100000];
        }

        applyLowPowerFrequencyProperties();

        [controller updateCPU];
        [controller updateGPU];
        [controller updatePackage];
    } @catch (NSException *exception) {
        NSLog(S("[CPUthermal] MitigationController 低功耗下发异常: %@"), exception);
    } @finally {
        g_applyingLowPowerMode--;
    }
}

static void applyFullPowerToThermalManager(ThermalManager *manager) {
    if (!manager) return;

    @try {
        [manager setThermalState:0];
        [manager putDeviceInThermalSimulationMode:S("nominal")];
        [manager putDeviceInLowTempSimulationMode:S("nominal")];
        [manager updatePowerzoneTelemetry];
    } @catch (NSException *exception) {
        NSLog(S("[CPUthermal] ThermalManager 满血辅助下发异常: %@"), exception);
    }
}

static void applyLowPowerToThermalManager(ThermalManager *manager) {
    if (!manager) return;

    @try {
        [manager putDeviceInLowTempSimulationMode:S("nominal")];
        [manager setThermalState:0];
        [manager updatePowerzoneTelemetry];
    } @catch (NSException *exception) {
        NSLog(S("[CPUthermal] ThermalManager 低功耗辅助下发异常: %@"), exception);
    }
}

static void applyFullPowerMode(void) {
    NSLog(S("[CPUthermal] ★ 应用满血模式 — 解除全部温控"));
    applyFullPowerToMitigationController(activeMitigationController());
    applyFullPowerToThermalManager(g_thermalManager);
}

static void applyLowPowerMode(void) {
    NSLog(S("[CPUthermal] ★ 应用低功耗模式 — 固定 %dMHz 限频并立即限制功率"),
          lowPowerCPUFreqTargetMHz());

    applyLowPowerFrequencyProperties();
    applyLowPowerToMitigationController(activeMitigationController());
    applyLowPowerToThermalManager(g_thermalManager);
}

static void scheduleLowPowerReapply(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (g_enabled && g_powerMode == PowerModeLowPower && !isTemperatureAboveSafetyCeiling()) {
            applyLowPowerMode();
        }
    });
}

static void stopLowPowerReapplyTimer(void) {
    if (!g_lowPowerReapplyTimer) return;

    dispatch_source_cancel(g_lowPowerReapplyTimer);
    g_lowPowerReapplyTimer = NULL;
}

static void startLowPowerReapplyTimer(void) {
    if (g_lowPowerReapplyTimer) return;

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    g_lowPowerReapplyTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (!g_lowPowerReapplyTimer) return;

    dispatch_source_set_timer(g_lowPowerReapplyTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        (uint64_t)(1.0 * NSEC_PER_SEC),
        (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(g_lowPowerReapplyTimer, ^{
        if (g_enabled && g_cpuProtection && g_powerMode == PowerModeLowPower && !isTemperatureAboveSafetyCeiling()) {
            applyLowPowerFrequencyProperties();
            applyLowPowerToMitigationController(activeMitigationController());
        }
    });
    dispatch_resume(g_lowPowerReapplyTimer);
}

// ============================================================================
// ★ 新增自 Insulation: 执行功率模式
// ============================================================================
static void applyPowerMode(void) {
    if (!g_enabled) return;

    // 安全阀检查
    if (isTemperatureAboveSafetyCeiling()) {
        NSLog(S("[CPUthermal] 温度超过安全阀 (75°C)，跳过功率模式应用"));
        return;
    }

    switch (g_powerMode) {
        case PowerModeFullPower:
            stopLowPowerReapplyTimer();
            applyFullPowerMode();
            break;
        case PowerModeLowPower:
        default:
            startLowPowerReapplyTimer();
            applyLowPowerMode();
            scheduleLowPowerReapply(0.05);
            scheduleLowPowerReapply(0.25);
            scheduleLowPowerReapply(1.0);
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
        if (g_powerMode == PowerModeLowPower) {
            [self putDeviceInLowTempSimulationMode:S("nominal")];
        }
        NSLog(S("[CPUthermal] CommonProduct init, 已重置热状态为 nominal"));
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

- (void)putDeviceInLowTempSimulationMode:(id)mode {
    if (shouldClampLowPowerCPU()) {
        %orig(S("nominal"));
        return;
    }
    %orig(mode);
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
        %orig(kLowPowerCPULevel);
        return;
    }
    %orig(level);
}

- (void)setCPUPowerCeiling:(double)ceiling fromDecisionSource:(id)source {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerCPUPowerMax(), S("CPUthermal"));
        return;
    }
    %orig(ceiling, source);
}

- (void)setCPUPowerFloor:(double)floor fromDecisionSource:(id)source {
    if (shouldClampLowPowerCPU()) {
        %orig((double)lowPowerCPUPowerFloor(), S("CPUthermal"));
        return;
    }
    %orig(floor, source);
}

- (void)setCPUPowerZoneTarget:(double)target {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerCPUPowerMax());
        return;
    }
    %orig(target);
}

- (void)setMaxCPUPowerTarget:(double)target useLegacyPath:(BOOL)legacy setProperty:(BOOL)setProperty {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerCPUPowerMax(), YES, YES);
        applyLowPowerFrequencyProperties();
        return;
    }
    %orig(target, legacy, setProperty);
}

- (void)setCPULowPowerTarget:(double)target {
    if (shouldClampLowPowerCPU()) {
        %orig((double)lowPowerCPUFreqTargetMHz());
        return;
    }
    %orig(target);
}

- (void)setMaxPackagePower:(double)power {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerPackagePowerMax());
        return;
    }
    %orig(power);
}

- (void)setPackagePowerCeiling:(double)ceiling fromDecisionSource:(id)source {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerPackagePowerMax(), S("CPUthermal"));
        return;
    }
    %orig(ceiling, source);
}

- (void)setPackagePowerFloor:(double)floor fromDecisionSource:(id)source {
    if (shouldClampLowPowerCPU()) {
        %orig((double)lowPowerCPUPowerFloor(), S("CPUthermal"));
        return;
    }
    %orig(floor, source);
}

- (void)setPackageLowPowerTarget {
    %orig;
    if (shouldClampLowPowerCPU()) {
        applyLowPowerFrequencyProperties();
    }
}

- (void)setPackagePowerZoneTarget {
    %orig;
    if (shouldClampLowPowerCPU()) {
        applyLowPowerFrequencyProperties();
    }
}

- (void)setPowerSaveActive:(BOOL)active {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerPowerSaveActive());
        return;
    }
    %orig(active);
}

- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
    if (shouldClampLowPowerCPU()) {
        %orig(YES);
        return;
    }
    %orig(enabled);
}

- (void)updateCPU {
    %orig;
    if (shouldClampLowPowerCPU()) {
        applyLowPowerFrequencyProperties();
    }
}

- (void)updatePackage {
    %orig;
    if (shouldClampLowPowerCPU()) {
        applyLowPowerFrequencyProperties();
    }
}

// 决策树评估
- (void)evaluateDecisionTree {
    if (shouldBlockCPUMitigation()) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(S("[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)"));
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

// --- MitigationController: 真实 CPU/GPU/Package 功率控制器 ---
%hook MitigationController

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
    if (res) {
        g_mitigationController = res;
        if (g_enabled) {
            applyPowerMode();
        }
    }
    return res;
}

- (void)setCPULevel:(int)level {
    if (shouldClampLowPowerCPU()) {
        %orig(80);
        return;
    }
    %orig(level);
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(int)source {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerCPUFreqTargetMHz(), source);
        return;
    }
    %orig(ceiling, source);
}

- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(int)source {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerCPUPowerFloor(), source);
        return;
    }
    %orig(floor, source);
}

- (void)setCPUPowerZoneTarget:(int)target {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerCPUFreqTargetMHz());
        return;
    }
    %orig(target);
}

- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(CFStringRef)property {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerCPUFreqTargetMHz(), YES, property);
        applyLowPowerFrequencyProperties();
        return;
    }
    %orig(target, legacy, property);
}

- (void)setCPULowPowerTarget:(int)target {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerCPUFreqTargetMHz());
        return;
    }
    %orig(target);
}

- (void)setMaxPackagePower:(int)power {
    if (shouldClampLowPowerCPU()) {
        %orig((int)lowPowerPackagePowerMax());
        return;
    }
    %orig(power);
}

- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(int)source {
    if (shouldClampLowPowerCPU()) {
        %orig((int)lowPowerPackagePowerMax(), source);
        return;
    }
    %orig(ceiling, source);
}

- (void)setPackagePowerFloor:(int)floor fromDecisionSource:(int)source {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerCPUPowerFloor(), source);
        return;
    }
    %orig(floor, source);
}

- (void)setPackageLowPowerTarget {
    %orig;
    if (shouldClampLowPowerCPU()) {
        applyLowPowerFrequencyProperties();
    }
}

- (void)setPackagePowerZoneTarget {
    %orig;
    if (shouldClampLowPowerCPU()) {
        applyLowPowerFrequencyProperties();
    }
}

- (void)setPowerSaveActive:(BOOL)active {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerPowerSaveActive());
        return;
    }
    %orig(active);
}

- (void)setPowerSaveToken:(int)token {
    if (shouldClampLowPowerCPU()) {
        %orig(lowPowerPowerSaveToken());
        return;
    }
    %orig(token);
}

- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
    if (shouldClampLowPowerCPU()) {
        %orig(YES);
        return;
    }
    %orig(enabled);
}

- (void)updateCPU {
    %orig;
    if (shouldClampLowPowerCPU()) {
        applyLowPowerFrequencyProperties();
    }
}

- (void)updatePackage {
    %orig;
    if (shouldClampLowPowerCPU()) {
        applyLowPowerFrequencyProperties();
    }
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
    if (!g_enabled) return;

    if (g_cpuProtection && g_powerMode == PowerModeLowPower) {
        NSMutableDictionary *powerSaveParams = [[dict objectForKey:S("powerSaveParams")] mutableCopy];
        if (!powerSaveParams) {
            powerSaveParams = [NSMutableDictionary dictionary];
        }
        powerSaveParams[S("CPUMaxPower")] = @(lowPowerCPUPowerMax());
        powerSaveParams[S("CPUPowerTarget")] = @(lowPowerCPUPowerMax());
        powerSaveParams[S("CPULowPowerTarget")] = @(lowPowerCPUPowerMax());
        powerSaveParams[S("PackageLowPowerTarget")] = @(lowPowerPackagePowerMax());
        dict[S("powerSaveParams")] = powerSaveParams;
    }

    if (!g_brightnessProtection) return;

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
    if (g_enabled && (g_cpuProtection || g_brightnessProtection) && [path isKindOfClass:[NSString class]]) {
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
        NSDictionary *prefs = loadPrefsDictionary();
        NSString *level = prefs[S("thermalPuppetValue")] ?: S("nominal");
        [g_commonProduct putDeviceInThermalSimulationMode:level];
        NSLog(S("[CPUthermal] Puppet 事件: 热模式=%@ 功率模式=%ld 屏蔽通知=%d"),
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
        NSLog(S("[CPUthermal] 功率模式已变更: %ld 屏蔽通知=%d"),
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
            NSLog(S("[CPUthermal] 配置关闭，跳过加载"));
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
                NSLog(S("[CPUthermal] IOServiceSetProperty hook 已安装"));
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
                NSLog(S("[CPUthermal] _getConfigurationFor hook 已安装"));
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

        NSLog(S("[CPUthermal] 温控防护已激活 — 安全阀:%d°C CPU:%d 亮度:%d 热状态:%d HID:%d CPMS:%d 功率模式:%ld 屏蔽通知:%d"),
              (int)(kSafetyTempThreshold / 1000),
              g_cpuProtection, g_brightnessProtection, g_thermalStateProtection,
              g_blockHidEvents, g_keepCPSMAlive,
              (long)g_powerMode, g_suppressThermalNotifications);
    }
}
