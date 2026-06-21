#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#include <roothide.h>
#import <IOKit/IOKitLib.h>
#import <SystemConfiguration/SCPreferences.h>

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
static const int64_t kSafetyTempThreshold = 75000;  // 75°C (毫摄氏度)

// 注意: 用 C 字符串而非 ObjC 常量，避免 roothide 重映射破坏 __cfstring
static const char *kPrefPathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";

static CommonProduct *g_commonProduct = nil;
static ThermalManager *g_thermalManager = nil;

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
// thermalmonitord 内部判定"高温"的阈值通常在 45°C-65°C 之间
// 我们设置 75°C 作为硬性安全阀 — 超过此温度不拦截任何保护动作
// 这样即使插件出 bug 导致温度失控，硬件仍能获得保护
static BOOL isTemperatureAboveSafetyCeiling(void) {
    // 如果关闭了安全阀或者没有启用，直接返回 NO
    if (!g_keepCPSMAlive) return NO;

    // 通过 IOKit 读取实际温度 — 跳过拦截
    // 如果读不到，保守返回 NO（不过度保护）
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
    if (g_cpuProtection && SELECTOR_IS_MITIGATION(selector)) {
        // 注意: 不拦截 0x60-0x6F 紧急保护
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
    if (g_cpuProtection) {
        static NSArray *cpuKeys;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // 用 C 字符串创建数组，避免 __cfstring
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
    if ([ks localizedCaseInsensitiveContainsString:S("freq")] ||
        [ks localizedCaseInsensitiveContainsString:S("speed")]) {
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

// --- notify_post — 拦截高温广播 ---
%hookf(uint32_t, notify_post, const char *name) {
    if (g_enabled && (g_thermalStateProtection || g_suppressTempPopup) && name) {
        // 安全阀: 只有在温度正常时才拦截
        if (!isTemperatureAboveSafetyCeiling()) {
            // 动态创建 NSString 避免 roothide __cfstring 损坏
            NSString *ns = [NSString stringWithUTF8String:name];
            // 常规热状态通知拦截
            if ([ns containsString:S("thermalstate")] || ([ns containsString:S("thermal")] && [ns containsString:S("high")])) {
                return NOTIFY_STATUS_OK;
            }
            // 禁温度计弹窗: 额外拦截热压力级别通知
            if (g_suppressTempPopup && [ns containsString:S("thermalpressurelevel")]) {
                return NOTIFY_STATUS_OK;
            }
        }
    }
    return %orig;
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
    if (g_enabled && g_cpuProtection) {
        // 阻止所有热缓解动作
        return;
    }
    %orig;
}

- (void)simulateLightThermalPressure {
    if (g_enabled && g_cpuProtection) {
        return;
    }
    %orig;
}

- (void)updatePowerzoneTelemetry {
    if (g_enabled && g_cpuProtection) {
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
// ObjC 类钩子（第2层: ThermalManager 决策层 — 新增自 1.dylib 分析）
//
// 冲突避免说明:
//   - 传感器读数 getHighestSkinTemp/dieTempFilteredMaxAverage/thermalSensorValuesMaxFromIndexSet
//     不在此处 hook (IOKit 层已拦截)
//   - putDeviceInThermalSimulationMode: 不 hook (CPUthermal 自已调用会递归)
//   - setCPMSMitigationState: 不 hook (IOKit 层已拦截 selector 0x40-0x5F)
//   - setHiPFeatureEnabled/setPackageLowPowerTarget: 不 hook (IOKit 层已拦截)
// ============================================================================

// --- ThermalManager: hook 决策树和热压力升级 ---
%hook ThermalManager

// 决策树评估 — 这是 thermalmonitord 判断"要不要降频"的核心
- (void)evaluateDecisionTree {
    if (g_enabled && g_cpuProtection) {
        // 安全阀: 超过 75°C 不阻断
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
            return;
        }
    }
    %orig;
}

// 是否应执行轻度热压力 — 可阻止
- (BOOL)shouldEnforceLightThermalPressure {
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止 enforceLightThermalPressure");
            return NO;
        }
    }
    return %orig;
}

// 获取组件释放速率 — 可以降低不放 0
- (float)getReleaseRateForComponent:(id)component {
    if (g_enabled && g_cpuProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            float rate = %orig(component);
            // 软化: 降低 50% 但保留基础释放能力
            if (rate > 0.5) {
                rate = rate * 0.5;
            }
            NSLog(@"[CPUthermal] 软化释放速率: %@ -> %.2f", component, rate);
            return rate;
        }
    }
    return %orig(component);
}

// 获取强制热级别 — 返回最低级
- (int)getPotentialForcedThermalLevel:(id)component {
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 覆盖强制热级别: %@ -> 0 (nominal)", component);
            return 0; // kThermalLevelNominal
        }
    }
    return %orig(component);
}

// 获取强制热压力级别 — 返回最低
- (int)getPotentialForcedThermalPressureLevel {
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 覆盖强制热压力级别 -> 0");
            return 0;
        }
    }
    return %orig;
}

// 散热/电池服务建议 — 关闭时返回 nil 屏蔽系统散热提示
// (适配自 fuckThermal 逆向还原分析)
- (id)getBatteryServiceSuggestion:(id)suggestion {
    id result = %orig(suggestion);
    if (g_enabled && g_thermalStateProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 拦截 ThermalManager 散热建议");
            return nil;
        }
    }
    return result;
}

// === 新增: 存储 ThermalManager 引用 + 应用低电模拟 (适配自 Insulation) ===
- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table {
    id res = %orig(components, hotspots, table);
    if (res && g_enabled) {
        g_thermalManager = res;
        NSLog(@"[CPUthermal] ThermalManager 已初始化");
        if (g_lowPowerSimulation) {
            applyLowPowerSimulation();
        }
    }
    return res;
}

// 热通知 — 加强: 新增 g_suppressTempPopup 检查
- (void)updateThermalNotification:(id)notification {
    if (g_enabled && (g_thermalStateProtection || g_suppressTempPopup)) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止热通知: %@", notification);
            return;
        }
    }
    %orig;
}

// 热压力升级通知 — 加强: 新增 g_suppressTempPopup 检查
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force {
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

// 计算控制力度 — 这是 throttle 量的核心
// soften 模式下减半但不归零，保留基础调节能力
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
    if (g_enabled && g_cpuProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            float effort = %orig(trigger, arg2);
            float newEffort = effort * 0.5;  // 减半，不归零
            if (newEffort < 0 && effort > 0) newEffort = 0;  // 保护负值
            NSLog(@"[CPUthermal] 软化控制力度: %.2f -> %.2f", effort, newEffort);
            return newEffort;
        }
    }
    return %orig(trigger, arg2);
}

// actionComponentControl — 组件控制动作
- (void)actionComponentControl {
    if (g_enabled && g_cpuProtection) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止 actionComponentControl");
            return;
        }
    }
    %orig;
}

// readReleaseRateForAllComponents — 全组件释放速率
- (void)readReleaseRateForAllComponents {
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
// C 函数钩子: _getConfigurationFor → ___New_getConfigurationFor___
//
// 在 thermalmonitord 初始化时，会调用 _getConfigurationFor(NSString*)
// 来获取热配置字典。通过返回修改后的配置，可以影响所有热管理参数。
// ============================================================================

// 原函数类型: NSDictionary* _getConfigurationFor(NSString *key)
static NSDictionary* (*orig_getConfigurationFor)(NSString *key) = NULL;

static NSDictionary* new_getConfigurationFor(NSString *key) {
    NSDictionary *config = orig_getConfigurationFor(key);
    if (!g_enabled || !g_cpuProtection || !config) return config;

    // 安全阀
    if (isTemperatureAboveSafetyCeiling()) return config;

    @autoreleasepool {
        NSMutableDictionary *modified = [config mutableCopy];
        if (!modified) return config;

        // 修改系统热配置
        // 增大所有热等级的触发阈值（延迟触发）
        static NSArray *tempThresholdKeys;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // 用 C 字符串创建数组，避免 __cfstring
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
                    // 将每个阈值提高 5°C (5000 毫摄氏度)
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
// 热配置 plist 修补（适配自 insulation 的 IDictHepler）
// ============================================================================
static void patchThermalPlistDict(NSMutableDictionary *dict) {
    if (!g_enabled || !g_brightnessProtection) return;

    // 用 C 字符串 key 动态创建，避免 __cfstring
    NSMutableDictionary *backlight = [[dict objectForKey:S("backlightComponentControl")] mutableCopy];
    if (!backlight) return;

    // 锁定背光亮度数组 — 所有 thermal 级别亮度一致（不降亮度）
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

    // 禁用 CPMS（CPU/GPU 电源管理子系统）
    // 注: 如果 g_keepCPSMAlive 为 YES，不关闭 CPMS
    if (!g_keepCPSMAlive) {
        backlight[S("expectsCPMSSupport")] = @0;
    }

    dict[S("backlightComponentControl")] = backlight;
}

// --- NSDictionary: 拦截 thermal plist 加载并修补 ---
// 注意: hook 系统类有风险，仅在亮度保护开启时实际执行
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
    id res = %orig;
    if (g_enabled && g_brightnessProtection && [path isKindOfClass:[NSString class]]) {
        NSString *pathStr = (NSString *)path;
        if ([pathStr containsString:S("/System/Library/ThermalMonitor/")]) {
            // 安全阀
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
// 模拟低电频率 — 主动压低 CPU/Package 功率 (适配自 Insulation 逆向)
// ============================================================================
static void applyLowPowerSimulation(void) {
    if (!g_thermalManager || !g_enabled) return;
    @autoreleasepool {
        NSLog(@"[CPUthermal] 激活模拟低电频率");

        // 开启省电模式
        [g_thermalManager setPowerSaveActive:YES];

        // 压低 CPU 功率目标
        [g_thermalManager setCPULowPowerTarget:0];

        // 设置 CPU 功率上限为低值
        [g_thermalManager setCPUPowerCeiling:500 fromDecisionSource:S("CPUthermal")];

        // 设置 Package 低功耗目标
        [g_thermalManager setPackageLowPowerTarget];

        // 设置 Package 功率上限
        [g_thermalManager setPackagePowerCeiling:500 fromDecisionSource:S("CPUthermal")];

        // GPU 也压低
        [g_thermalManager setGPUPowerCeiling:500 fromDecisionSource:S("CPUthermal")];

        // 强制 CPU 最低级别
        [g_thermalManager setCPULevel:0];

        // 限制最大 Package 功率
        [g_thermalManager setMaxPackagePower:1000];

        // 触发更新
        [g_thermalManager updateCPU];
        [g_thermalManager updateGPU];
        [g_thermalManager updatePackage];

        NSLog(@"[CPUthermal] 模拟低电频率已应用");
    }
}

// ============================================================================
// 禁温度计弹窗 — 通过 SCPreferences + 通知阻断 (适配自 Insulation 逆向)
//
// SCPreferences API 在 iOS SDK 中被标记为 unavailable， 无法直接链接
// 通过 dlsym 运行时动态加载 SystemConfiguration.framework 中的函数指针
// ============================================================================
static void applySuppressTempPopup(BOOL enable) {
    @autoreleasepool {
        NSLog(@"[CPUthermal] %@ 温度计弹窗", enable ? S("禁用") : S("恢复"));

        // 运行时动态加载 SystemConfiguration
        void *sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW | RTLD_GLOBAL);
        if (!sc) {
            NSLog(@"[CPUthermal] 无法加载 SystemConfiguration.framework");
            return;
        }

        // dlsym 获取 SCPreferences API 函数指针
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

        // 创建 SCPreferences 会话
        SCPreferencesRef prefs = dyn_SCPreferencesCreate(NULL,
            (__bridge CFStringRef)S("CPUthermal"),
            (__bridge CFStringRef)S("OSThermalStatus"));
        if (!prefs) {
            NSLog(@"[CPUthermal] SCPreferencesCreate 失败");
            dlclose(sc);
            return;
        }

        // 禁用/启用 OS 热通知
        dyn_SCPreferencesSetValue(prefs,
            (__bridge CFStringRef)S("OSThermalNotificationEnabled"),
            enable ? kCFBooleanFalse : kCFBooleanTrue);

        // 持久化禁用的热通知状态
        dyn_SCPreferencesSetValue(prefs,
            (__bridge CFStringRef)S("OSThermalNotificationPersistentlyEnabled"),
            enable ? kCFBooleanFalse : kCFBooleanTrue);

        // 禁用高温 override
        dyn_SCPreferencesSetValue(prefs,
            (__bridge CFStringRef)S("hipOverride"),
            enable ? kCFBooleanFalse : kCFBooleanTrue);

        // 持久化禁用
        dyn_SCPreferencesSetValue(prefs,
            (__bridge CFStringRef)S("hipPersistentlyEnabled"),
            enable ? kCFBooleanFalse : kCFBooleanTrue);

        // 提交 + 应用
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
// 运行时配置重载（设置变更后不重启 thermalmonitord 即时生效）
// ============================================================================
static void reloadSettings(void) {
    @autoreleasepool {
        NSLog(@"[CPUthermal] 运行时重载配置...");
        loadPrefs();
        if (!g_enabled) return;

        // 重新应用低电模拟
        if (g_lowPowerSimulation && g_thermalManager) {
            applyLowPowerSimulation();
        }

        // 重新应用弹窗抑制
        applySuppressTempPopup(g_suppressTempPopup);
    }
}

// ============================================================================
// Puppet 事件（由 Preferences 面板触发 — 模拟热级别切换）
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

        // 确保 IOKit 已加载
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

        // _getConfigurationFor — C 函数钩子
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

        // 启动时立即应用禁温度计弹窗 (SCPreferences 写入)
        if (g_suppressTempPopup) {
            applySuppressTempPopup(YES);
        }

        NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:%d°C CPU:%d 亮度:%d 热状态:%d HID:%d CPMS:%d 低电模拟:%d 禁弹窗:%d",
              (int)(kSafetyTempThreshold / 1000),
              g_cpuProtection, g_brightnessProtection, g_thermalStateProtection,
              g_blockHidEvents, g_keepCPSMAlive,
              g_lowPowerSimulation, g_suppressTempPopup);

        // 设置变更监听 — 不重启 thermalmonitord 即时生效
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            // 设置变更通知
            CFNotificationCenterAddObserver(c, NULL, onSettingsChanged,
                (__bridge CFStringRef)S("com.huayuarc.CPUthermal/settingsChanged"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

            // 模拟热级别监听（独立功能）
            CFNotificationCenterAddObserver(c, NULL, onPuppetEvent,
                (__bridge CFStringRef)S("com.huayuarc.CPUthermal.puppet"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}
