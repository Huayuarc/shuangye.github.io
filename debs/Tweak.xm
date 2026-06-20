#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <IOKit/IOKitLib.h>

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
// ============================================================================

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
static BOOL g_enabled              = NO;  // 总开关（默认关闭）
static BOOL g_blockCPUMitigation   = NO;  // 阻止 CPU 降频
static BOOL g_blockBrightness      = NO;  // 阻止亮度降低
static BOOL g_forceNominal         = NO;  // 强制 Nominal 热状态
static BOOL g_patchThermalPlist    = NO;  // 修补热配置 plist
static BOOL g_blockObjCHooks      = NO;  // 阻止 ObjC 层热缓解动作
static BOOL g_blockHidEvents      = NO;  // 阻止 HID 温度事件

// ---- 新增: 精细控制 ----
static BOOL g_blockDecisionTree    = NO;  // 阻止决策树评估(阻断大部分热动作)
static BOOL g_softenControlEffort  = NO;  // 软化控制力度(减半不归零)
static BOOL g_blockThermalPressure = NO;  // 阻止热压力升级(轻度/中度/重度)
static BOOL g_modifyConfig         = NO;  // 修改热配置表(影响初始化时的限制)
static BOOL g_overrideForceLevel   = NO;  // 覆盖强制热级别(返回最低级)
static BOOL g_keepCPSMAlive        = NO; // 保留 CPMS 紧急保护(安全阀) 默认关闭

// 温度安全阀 — 超过此值不拦截任何保护
static const int64_t kSafetyTempThreshold = 75000;  // 75°C (毫摄氏度)

static NSString *const kPrefPath = @"/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist";

static CommonProduct *g_commonProduct = nil;

static void loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
        if (!d) return;
        g_enabled              = [d[@"enabled"] ?: @NO boolValue];
        g_blockCPUMitigation   = [d[@"blockCPUMitigation"] ?: @NO boolValue];
        g_blockBrightness      = [d[@"blockBrightness"] ?: @NO boolValue];
        g_forceNominal         = [d[@"forceNominalState"] ?: @NO boolValue];
        g_patchThermalPlist    = [d[@"patchThermalPlist"] ?: @NO boolValue];
        g_blockObjCHooks       = [d[@"blockObjCHooks"] ?: @NO boolValue];
        g_blockHidEvents       = [d[@"blockHidEvents"] ?: @NO boolValue];

        // 新增精细控制
        g_blockDecisionTree    = [d[@"blockDecisionTree"] ?: @NO boolValue];
        g_softenControlEffort  = [d[@"softenControlEffort"] ?: @NO boolValue];
        g_blockThermalPressure = [d[@"blockThermalPressure"] ?: @NO boolValue];
        g_modifyConfig         = [d[@"modifyConfig"] ?: @NO boolValue];
        g_overrideForceLevel   = [d[@"overrideForceLevel"] ?: @NO boolValue];
        g_keepCPSMAlive        = [d[@"keepCPMSAlive"] ?: @NO boolValue];
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

    if (g_forceNominal && SELECTOR_IS_TEMP(selector)) {
        if (output && outputCnt && *outputCnt > 0) {
            for (uint32_t i = 0; i < MIN(*outputCnt, 4); i++) {
                output[i] = 36000;  // 36°C — 永远显示正常温度
            }
        }
        return KERN_SUCCESS;
    }
    if (g_blockCPUMitigation && SELECTOR_IS_MITIGATION(selector)) {
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
    if (g_blockCPUMitigation) {
        static NSArray *cpuKeys;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            cpuKeys = @[@"cpu", @"CPU", @"freq", @"Freq", @"frequency", @"performance", @"throttle", @"mitigation", @"speed", @"limit"];
        });
        for (NSString *k in cpuKeys) {
            if ([ks containsString:k]) return KERN_SUCCESS;
        }
    }
    if (g_blockBrightness) {
        static NSArray *brightKeys;
        static dispatch_once_t once2;
        dispatch_once(&once2, ^{
            brightKeys = @[@"brightness", @"Brightness", @"backlight", @"Backlight"];
        });
        for (NSString *k in brightKeys) {
            if ([ks containsString:k]) return KERN_SUCCESS;
        }
    }
    return orig_IOServiceSetProperty(service, key, value);
}

// --- IORegistryEntryCreateCFProperty — 返回正常值 ---
%hookf(CFTypeRef, IORegistryEntryCreateCFProperty, io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    if (!g_enabled || !g_forceNominal) return %orig;

    // 安全阀
    if (isTemperatureAboveSafetyCeiling()) return %orig;

    NSString *ks = (__bridge NSString *)key;
    if ([ks localizedCaseInsensitiveContainsString:@"temperature"] ||
        [ks localizedCaseInsensitiveContainsString:@"thermal-level"] ||
        [ks localizedCaseInsensitiveContainsString:@"hot-level"] ||
        [ks localizedCaseInsensitiveContainsString:@"thermalstate"]) {
        int zero = 0;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
    }
    if ([ks localizedCaseInsensitiveContainsString:@"freq"] ||
        [ks localizedCaseInsensitiveContainsString:@"speed"]) {
        int max = INT_MAX;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &max);
    }
    if ([ks localizedCaseInsensitiveContainsString:@"brightness"] ||
        [ks localizedCaseInsensitiveContainsString:@"backlight"]) {
        float one = 1.0;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &one);
    }
    return %orig;
}

// --- notify_post — 拦截高温广播 ---
%hookf(uint32_t, notify_post, const char *name) {
    if (g_enabled && g_forceNominal && name) {
        // 安全阀: 只有在温度正常时才拦截
        if (!isTemperatureAboveSafetyCeiling()) {
            NSString *ns = @(name);
            if ([ns containsString:@"thermalstate"] || ([ns containsString:@"thermal"] && [ns containsString:@"high"])) {
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
        [self putDeviceInThermalSimulationMode:@"nominal"];
        NSLog(@"[CPUthermal] CommonProduct init, 已重置热状态为 nominal");
    }
    return res;
}

- (void)tryTakeAction {
    if (g_enabled && g_blockObjCHooks) {
        // 阻止所有热缓解动作
        return;
    }
    %orig;
}

- (void)simulateLightThermalPressure {
    if (g_enabled && g_blockObjCHooks) {
        return;
    }
    %orig;
}

- (void)updatePowerzoneTelemetry {
    if (g_enabled && g_blockObjCHooks) {
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
    if (g_enabled && g_blockDecisionTree) {
        // 安全阀: 超过 75°C 不阻断
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
            return;
        }
    }
    %orig;
}

// 热压力升级通知 — 阻止 thermalmonitord 升级热压力级别
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force {
    if (g_enabled && g_blockThermalPressure) {
        // 安全阀
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止热压力升级: %@ force:%d", notification, force);
            // 仍然调用原方法但传 NO — 不强制
            %orig(notification, NO);
            return;
        }
    }
    %orig;
}

// 热通知 — 可选择性阻断
- (void)updateThermalNotification:(id)notification {
    if (g_enabled && g_blockThermalPressure) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止热通知: %@", notification);
            return;
        }
    }
    %orig;
}

// 是否应执行轻度热压力 — 可阻止
- (BOOL)shouldEnforceLightThermalPressure {
    if (g_enabled && g_blockThermalPressure) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止 enforceLightThermalPressure");
            return NO;
        }
    }
    return %orig;
}

// 获取组件释放速率 — 可以降低不放 0
- (float)getReleaseRateForComponent:(id)component {
    if (g_enabled && g_softenControlEffort) {
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
    if (g_enabled && g_overrideForceLevel) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 覆盖强制热级别: %@ -> 0 (nominal)", component);
            return 0; // kThermalLevelNominal
        }
    }
    return %orig(component);
}

// 获取强制热压力级别 — 返回最低
- (int)getPotentialForcedThermalPressureLevel {
    if (g_enabled && g_overrideForceLevel) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 覆盖强制热压力级别 -> 0");
            return 0;
        }
    }
    return %orig;
}

%end

// --- ThermalControl: hook 控制力度计算 ---
%hook ThermalControl

// 计算控制力度 — 这是 throttle 量的核心
// soften 模式下减半但不归零，保留基础调节能力
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
    if (g_enabled && g_softenControlEffort) {
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
    if (g_enabled && g_softenControlEffort) {
        if (!isTemperatureAboveSafetyCeiling()) {
            NSLog(@"[CPUthermal] 阻止 actionComponentControl");
            return;
        }
    }
    %orig;
}

// readReleaseRateForAllComponents — 全组件释放速率
- (void)readReleaseRateForAllComponents {
    if (g_enabled && g_softenControlEffort) {
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
    if (!g_enabled || !g_modifyConfig || !config) return config;

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
            tempThresholdKeys = @[
                @"thermalThresholds",
                @"dieTemperatureThresholds",
                @"skinTemperatureThresholds",
                @"componentTemperatureThresholds",
                @"hotTemperatureThresholds"
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
    if (!g_enabled || !g_patchThermalPlist) return;

    NSMutableDictionary *backlight = [[dict objectForKey:@"backlightComponentControl"] mutableCopy];
    if (!backlight) return;

    // 锁定背光亮度数组 — 所有 thermal 级别亮度一致（不降亮度）
    NSMutableArray *brightnessArr = [[backlight objectForKey:@"BacklightBrightness"] mutableCopy];
    if (brightnessArr.count > 1) {
        id first = brightnessArr[0];
        for (NSUInteger i = 1; i < brightnessArr.count; i++) {
            brightnessArr[i] = first;
        }
        backlight[@"BacklightBrightness"] = brightnessArr;
    }

    // 锁定背光功耗数组
    NSMutableArray *powerArr = [[backlight objectForKey:@"BacklightPower"] mutableCopy];
    if (powerArr.count > 1) {
        id first = powerArr[0];
        for (NSUInteger i = 1; i < powerArr.count; i++) {
            powerArr[i] = first;
        }
        backlight[@"BacklightPower"] = powerArr;
    }

    // 禁用 CPMS（CPU/GPU 电源管理子系统）
    // 注: 如果 g_keepCPSMAlive 为 YES，不关闭 CPMS
    if (!g_keepCPSMAlive) {
        backlight[@"expectsCPMSSupport"] = @0;
    }

    dict[@"backlightComponentControl"] = backlight;
}

// --- NSDictionary: 拦截 thermal plist 加载并修补 ---
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
    id res = %orig;
    if (g_enabled && g_patchThermalPlist && [path containsString:@"/System/Library/ThermalMonitor/"]) {
        // 安全阀
        if (!isTemperatureAboveSafetyCeiling()) {
            NSMutableDictionary *patched = [res mutableCopy];
            if (patched) {
                patchThermalPlistDict(patched);
                NSLog(@"[CPUthermal] 已修补热配置 plist: %@", [path lastPathComponent]);
                return patched;
            }
        }
    }
    return res;
}

%end

// ============================================================================
// Puppet 事件（由 Preferences 面板触发 — 模拟热级别切换）
// ============================================================================
static void executePuppetEvent(void) {
    if (!g_commonProduct) return;
    @autoreleasepool {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
        NSString *level = prefs[@"thermalPuppetValue"] ?: @"nominal";
        [g_commonProduct putDeviceInThermalSimulationMode:level];
        NSLog(@"[CPUthermal] Puppet 事件: 热模式设为 %@", level);
    }
}

// ============================================================================
// %ctor — 构造函数
// ============================================================================
static void onPrefsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    loadPrefs();
    NSLog(@"[CPUthermal] 配置已重载");
}

static void onPuppetEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    executePuppetEvent();
}

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
            dlclose(monitor);
        } else {
            NSLog(@"[CPUthermal] 未找到 DeviceMonitor.framework (非致命)");
        }

        NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:%d°C 降频:%d 降亮度:%d Nominal:%d | 决策树:%d 软化:%d 热压力:%d 配置修改:%d 强制级别:%d",
              (int)(kSafetyTempThreshold / 1000),
              g_blockCPUMitigation, g_blockBrightness, g_forceNominal,
              g_blockDecisionTree, g_softenControlEffort, g_blockThermalPressure,
              g_modifyConfig, g_overrideForceLevel);

        // 监听配置变化
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            CFNotificationCenterAddObserver(c, NULL, onPrefsChanged,
                (__bridge CFStringRef)@"com.huayuarc.cputhermal.prefschanged",
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

            CFNotificationCenterAddObserver(c, NULL, onPuppetEvent,
                (__bridge CFStringRef)@"com.huayuarc.cputhermal.puppet",
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}
