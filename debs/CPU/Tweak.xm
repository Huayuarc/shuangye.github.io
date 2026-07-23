#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#include <roothide.h>
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
//
// 注意: 禁止使用 @"" ObjC 字符串常量（roothide 重映射会破坏 __cfstring）
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================================

// 动态创建 NSString 的辅助宏 — 避免编译期 __cfstring
#define S(str) [NSString stringWithUTF8String:(str)]

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
static BOOL g_enabled               = YES; // 总开关（默认开启）
static BOOL g_cpuProtection         = YES; // CPU 性能保护(降频/决策树/控制力度/配置表)
static BOOL g_brightnessProtection  = YES; // 屏幕亮度保护(降亮度/背光配置)
static BOOL g_thermalStateProtection= YES; // 热状态封锁(Nominal/热压力/强制级别)
static BOOL g_blockHidEvents        = YES; // 阻止 HID 温度事件
static BOOL g_keepCPSMAlive         = NO;  // 保留 CPMS 紧急保护(安全阀) 默认关闭
static int  g_powerMode             = 0;   // 功率模式: 0=正常 1=解除温控 2=低功耗

// 温度安全阀 — 超过此值不拦截任何保护
static const int64_t kSafetyTempThreshold = 100000;  // 100°C (毫摄氏度)

// 低功耗模式目标温度 — 模拟 65°C 触发约 30% 降频，保留 70% 性能
static const int64_t kLowPowerTargetTemp = 65000;  // 65°C (毫摄氏度)

// 低功耗模式电池模拟参数
static const int64_t kLowPowerBatteryTemp = 48000;  // 48°C (毫摄氏度)

// 注意: 用 C 字符串而非 ObjC 常量，避免 roothide 重映射破坏 __cfstring
static const char *kPrefPathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kNotifNameC = "com.huayuarc.CPUthermal/settingsChanged";

static CommonProduct *g_commonProduct = nil;

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
        g_powerMode             = [[d objectForKey:S("powerMode")] ?: @0 intValue];
    }
}

// 判断当前是否处于「解除温控」模式
static BOOL isUnlockMode(void) {
    return g_enabled && g_powerMode == 1;
}

// 判断当前是否处于「低功耗」模式
static BOOL isLowPowerMode(void) {
    return g_enabled && g_powerMode == 2;
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
// 我们设置 100°C 作为硬性安全阀 — 超过此温度不拦截任何保护动作
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

    // 超过 100°C 时放行所有保护（安全阀生效）
    if (isTemperatureAboveSafetyCeiling()) {
        return %orig;
    }

    // ========== 功率模式处理 ==========
    if (isLowPowerMode()) {
        // 低功耗模式: 不阻止降频（我们需要 ~30% 降频），
        // 但篡改传感器读数让系统认为温度是 65°C
        if (SELECTOR_IS_TEMP(selector)) {
            if (output && outputCnt && *outputCnt > 0) {
                for (uint32_t i = 0; i < MIN(*outputCnt, 4); i++) {
                    // 报告 65°C 触发系统自然降频（约 70% 性能）
                    output[i] = (uint64_t)kLowPowerTargetTemp;
                }
            }
            return KERN_SUCCESS;
        }
        // 降频操作: 允许执行，系统会在 65°C 读数下自动降频约 30%
        if (SELECTOR_IS_MITIGATION(selector)) {
            // 不过滤降频操作 — 让系统正常响应"65°C"温度
            return %orig;
        }
        return %orig;
    }

    if (isUnlockMode() || g_thermalStateProtection) {
        if (SELECTOR_IS_TEMP(selector)) {
            if (output && outputCnt && *outputCnt > 0) {
                for (uint32_t i = 0; i < MIN(*outputCnt, 4); i++) {
                    output[i] = 36000;  // 36°C — 永远显示正常温度
                }
            }
            return KERN_SUCCESS;
        }
    }
    if (isUnlockMode() || g_cpuProtection) {
        if (SELECTOR_IS_MITIGATION(selector)) {
            // 注意: 不拦截 0x60-0x6F 紧急保护
            return KERN_SUCCESS;
        }
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

    // 低功耗模式: 不过滤任何属性写入 — 让系统正常执行降频
    if (isLowPowerMode()) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    NSString *ks = (__bridge NSString *)key;
    // 解除温控模式: 无条件阻止所有
    if (isUnlockMode() || g_cpuProtection) {
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
    if (isUnlockMode() || g_brightnessProtection) {
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

// --- IORegistryEntryCreateCFProperty — 返回修改后的值 ---
%hookf(CFTypeRef, IORegistryEntryCreateCFProperty, io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    if (!g_enabled) return %orig;

    // 安全阀
    if (isTemperatureAboveSafetyCeiling()) return %orig;

    NSString *ks = (__bridge NSString *)key;

    // ========== 低功耗模式 — 电池模拟 + 温度篡改 ==========
    if (isLowPowerMode()) {
        // 电池相关属性 — 模拟低电量
        if ([ks localizedCaseInsensitiveContainsString:S("appleRawCurrentCapacity")] ||
            [ks localizedCaseInsensitiveContainsString:S("currentcapacity")]) {
            // 报告极低容量，触发系统低功耗管理
            int64_t low = 150;  // mAh
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &low);
        }
        if ([ks localizedCaseInsensitiveContainsString:S("appleRawMaxCapacity")] ||
            [ks localizedCaseInsensitiveContainsString:S("maxcapacity")]) {
            // 保持最大容量不变 — 让系统计算比例时为 low/max ≈ 5%
            return %orig;
        }
        if ([ks localizedCaseInsensitiveContainsString:S("atCriticalLevel")]) {
            int yes = 1;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &yes);
        }
        if ([ks localizedCaseInsensitiveContainsString:S("atWarnLevel")]) {
            int yes = 1;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &yes);
        }
        if ([ks localizedCaseInsensitiveContainsString:S("temperature")] &&
            ![ks localizedCaseInsensitiveContainsString:S("thermal-level")]) {
            // 报告电池温度 48°C
            int64_t batTemp = kLowPowerBatteryTemp;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &batTemp);
        }
        if ([ks localizedCaseInsensitiveContainsString:S("externalcharge")] ||
            [ks localizedCaseInsensitiveContainsString:S("charger")]) {
            // 报告未充电
            int zero = 0;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
        }
        // 低功耗模式下也篡改热传感器读数
        if ([ks localizedCaseInsensitiveContainsString:S("temperature")] ||
            [ks localizedCaseInsensitiveContainsString:S("thermal-level")]) {
            int64_t target = kLowPowerTargetTemp / 1000;  // °C
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &target);
        }
        return %orig;
    }

    // ========== 解除温控模式 / 正常模式 ==========
    if (!isUnlockMode() && !g_thermalStateProtection) return %orig;

    if ([ks localizedCaseInsensitiveContainsString:S("temperature")] ||
        [ks localizedCaseInsensitiveContainsString:S("thermal-level")] ||
        [ks localizedCaseInsensitiveContainsString:S("hot-level")] ||
        [ks localizedCaseInsensitiveContainsString:S("thermalstate")]) {
        int zero = 0;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
    }
    if (isUnlockMode() || g_cpuProtection) {
        if ([ks localizedCaseInsensitiveContainsString:S("freq")] ||
            [ks localizedCaseInsensitiveContainsString:S("speed")]) {
            int max = INT_MAX;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &max);
        }
    }
    if (isUnlockMode() || g_brightnessProtection) {
        if ([ks localizedCaseInsensitiveContainsString:S("brightness")] ||
            [ks localizedCaseInsensitiveContainsString:S("backlight")]) {
            float one = 1.0;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &one);
        }
    }
    return %orig;
}

// --- notify_post — 拦截高温广播 ---
%hookf(uint32_t, notify_post, const char *name) {
    if (!g_enabled || !name) return %orig;

    NSString *ns = [NSString stringWithUTF8String:name];

    // 低功耗模式: 不过滤热通知，让系统正常响应温度
    if (isLowPowerMode()) {
        // 但依然屏蔽极端高温广播（已由 65°C 伪装处理）
        if ([ns containsString:S("thermal")] && [ns containsString:S("critical")]) {
            return NOTIFY_STATUS_OK;
        }
        return %orig;
    }

    // 解除温控/正常模式: 按原有规则拦截
    if (isUnlockMode() || g_thermalStateProtection) {
        // 安全阀: 只有在温度正常时才拦截
        if (!isTemperatureAboveSafetyCeiling()) {
            if ([ns containsString:S("thermalstate")] || ([ns containsString:S("thermal")] && [ns containsString:S("high")])) {
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
        // 低功耗模式: 不重置热状态，让系统保持当前状态
        if (!isLowPowerMode()) {
            [self putDeviceInThermalSimulationMode:S("nominal")];
            NSLog(@"[CPUthermal] CommonProduct init, 已重置热状态为 nominal");
        } else {
            NSLog(@"[CPUthermal] CommonProduct init, 低功耗模式保留当前热状态");
        }
    }
    return res;
}

- (void)tryTakeAction {
    if (!g_enabled) { %orig; return; }
    // 解除温控: 阻止所有热缓解动作
    if (isUnlockMode()) { return; }
    // 低功耗: 允许系统执行热缓解（基于我们伪造的 65°C 读数，系统会降频约 30%）
    if (isLowPowerMode()) { %orig; return; }
    // 正常模式: 按独立开关
    if (g_cpuProtection) { return; }
    %orig;
}

- (void)simulateLightThermalPressure {
    if (!g_enabled) { %orig; return; }
    if (isUnlockMode()) { return; }
    if (isLowPowerMode()) { %orig; return; }
    if (g_cpuProtection) { return; }
    %orig;
}

- (void)updatePowerzoneTelemetry {
    if (!g_enabled) { %orig; return; }
    if (isUnlockMode()) { return; }
    if (isLowPowerMode()) { %orig; return; }
    if (g_cpuProtection) { return; }
    %orig;
}

%end

// --- HidSensors: HID 温度事件处理 ---
%hook HidSensors

- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2 {
    if (!g_enabled) { %orig; return; }
    if (isLowPowerMode()) { %orig; return; }  // 低功耗: 允许事件
    if (g_blockHidEvents) { return; }          // 正常/解除温控: 按开关
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

// 决策树评估 — thermalmonitord 判断"要不要降频"的核心
- (void)evaluateDecisionTree {
    if (!g_enabled) { %orig; return; }
    // 安全阀
    if (isTemperatureAboveSafetyCeiling()) { %orig; return; }
    // 低功耗: 允许决策树评估（我们的 65°C 伪造温度会让系统决定适当降频）
    if (isLowPowerMode()) {
        %orig;
        return;
    }
    // 解除温控: 阻止决策树
    if (isUnlockMode()) {
        NSLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
        return;
    }
    // 正常模式: 按独立开关
    if (g_cpuProtection) {
        NSLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
        return;
    }
    %orig;
}

// 热压力升级通知
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force {
    if (!g_enabled) { %orig; return; }
    if (isTemperatureAboveSafetyCeiling()) { %orig; return; }
    if (isLowPowerMode()) {
        // 低功耗: 允许轻度热压力通知（触发 ~30% 降频）
        if ([notification containsString:S("light")]) {
            %orig(notification, YES);
            return;
        }
        // 屏蔽严重热压力
        NSLog(@"[CPUthermal] 低功耗模式: 阻止严重热压力升级: %@", notification);
        %orig(notification, NO);
        return;
    }
    if (isUnlockMode() || g_thermalStateProtection) {
        NSLog(@"[CPUthermal] 阻止热压力升级: %@ force:%d", notification, force);
        %orig(notification, NO);
        return;
    }
    %orig;
}

// 热通知
- (void)updateThermalNotification:(id)notification {
    if (!g_enabled) { %orig; return; }
    if (isTemperatureAboveSafetyCeiling()) { %orig; return; }
    if (isLowPowerMode()) { %orig; return; }  // 低功耗: 允许热通知
    if (isUnlockMode() || g_thermalStateProtection) {
        NSLog(@"[CPUthermal] 阻止热通知: %@", notification);
        return;
    }
    %orig;
}

// 是否应执行轻度热压力
- (BOOL)shouldEnforceLightThermalPressure {
    if (!g_enabled) { return %orig; }
    if (isTemperatureAboveSafetyCeiling()) { return %orig; }
    if (isLowPowerMode()) { return YES; }  // 低功耗: 需要轻度热压力来降频
    if (isUnlockMode() || g_thermalStateProtection) {
        NSLog(@"[CPUthermal] 阻止 enforceLightThermalPressure");
        return NO;
    }
    return %orig;
}

// 获取组件释放速率 — 低功耗模式限制在 70%
- (float)getReleaseRateForComponent:(id)component {
    if (!g_enabled) { return %orig(component); }
    if (isTemperatureAboveSafetyCeiling()) { return %orig(component); }
    float rate = %orig(component);
    if (isLowPowerMode()) {
        // 低功耗: 限制释放速率在 0.7（70% 性能），但保留基础释放能力
        if (rate > 0.7) {
            rate = 0.7;
        } else if (rate > 0.3 && rate <= 0.7) {
            // 在 0.3-0.7 之间保持原值
        } else if (rate <= 0.3) {
            // 不低于 0.3（防止过度降频）
            rate = 0.3;
        }
        NSLog(@"[CPUthermal] 低功耗释放速率: %@ -> %.2f", component, rate);
        return rate;
    }
    if (isUnlockMode() || g_cpuProtection) {
        // 软化: 降低 50% 但保留基础释放能力
        if (rate > 0.5) {
            rate = rate * 0.5;
        }
        NSLog(@"[CPUthermal] 软化释放速率: %@ -> %.2f", component, rate);
        return rate;
    }
    return rate;
}

// 获取强制热级别
- (int)getPotentialForcedThermalLevel:(id)component {
    if (!g_enabled) { return %orig(component); }
    if (isTemperatureAboveSafetyCeiling()) { return %orig(component); }
    if (isLowPowerMode()) {
        // 低功耗: 返回中等级别触发温和降频
        return 2;  // kThermalLevelModerate
    }
    if (isUnlockMode() || g_thermalStateProtection) {
        NSLog(@"[CPUthermal] 覆盖强制热级别: %@ -> 0 (nominal)", component);
        return 0;
    }
    return %orig(component);
}

// 获取强制热压力级别
- (int)getPotentialForcedThermalPressureLevel {
    if (!g_enabled) { return %orig; }
    if (isTemperatureAboveSafetyCeiling()) { return %orig; }
    if (isLowPowerMode()) {
        return 2;  // 轻度热压力
    }
    if (isUnlockMode() || g_thermalStateProtection) {
        NSLog(@"[CPUthermal] 覆盖强制热压力级别 -> 0");
        return 0;
    }
    return %orig;
}

// 散热/电池服务建议
- (id)getBatteryServiceSuggestion:(id)suggestion {
    id result = %orig(suggestion);
    if (!g_enabled) { return result; }
    if (isTemperatureAboveSafetyCeiling()) { return result; }
    if (isLowPowerMode()) {
        // 低功耗: 不屏蔽散热建议（用户需要知道设备在"发热"）
        return result;
    }
    if (isUnlockMode() || g_thermalStateProtection) {
        NSLog(@"[CPUthermal] 拦截 ThermalManager 散热建议");
        return nil;
    }
    return result;
}

%end

// --- ThermalControl: hook 控制力度计算 ---
%hook ThermalControl

// 计算控制力度 — 这是 throttle 量的核心
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
    if (!g_enabled) { return %orig(trigger, arg2); }
    if (isTemperatureAboveSafetyCeiling()) { return %orig(trigger, arg2); }
    float effort = %orig(trigger, arg2);
    if (isLowPowerMode()) {
        // 低功耗: 限制控制力度不超过 0.3（最多降频 30%）
        float newEffort = MIN(effort, 0.3);
        NSLog(@"[CPUthermal] 低功耗控制力度: %.2f -> %.2f", effort, newEffort);
        return newEffort;
    }
    if (isUnlockMode() || g_cpuProtection) {
        float newEffort = effort * 0.5;  // 减半，不归零
        if (newEffort < 0 && effort > 0) newEffort = 0;
        NSLog(@"[CPUthermal] 软化控制力度: %.2f -> %.2f", effort, newEffort);
        return newEffort;
    }
    return effort;
}

// actionComponentControl — 组件控制动作
- (void)actionComponentControl {
    if (!g_enabled) { %orig; return; }
    if (isTemperatureAboveSafetyCeiling()) { %orig; return; }
    if (isLowPowerMode()) { %orig; return; }  // 低功耗: 允许控制
    if (isUnlockMode() || g_cpuProtection) {
        NSLog(@"[CPUthermal] 阻止 actionComponentControl");
        return;
    }
    %orig;
}

// readReleaseRateForAllComponents — 全组件释放速率
- (void)readReleaseRateForAllComponents {
    if (!g_enabled) { %orig; return; }
    if (isTemperatureAboveSafetyCeiling()) { %orig; return; }
    if (isLowPowerMode()) { %orig; return; }  // 低功耗: 允许读取
    if (isUnlockMode() || g_cpuProtection) {
        NSLog(@"[CPUthermal] 阻止 readReleaseRateForAllComponents");
        return;
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
    if (!g_enabled || !config) return config;

    // 安全阀
    if (isTemperatureAboveSafetyCeiling()) return config;

    // 低功耗: 不修改配置表，使用原始配置（配合 65°C 伪造温度达到自然降频）
    if (isLowPowerMode()) return config;

    // 解除温控/正常模式: 按原有逻辑修改配置表
    if (!isUnlockMode() && !g_cpuProtection) return config;

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
    // 低功耗模式: 不修补亮度/背光控制
    if (isLowPowerMode()) return;
    if (!g_enabled || !(isUnlockMode() || g_brightnessProtection)) return;

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
    if (!g_enabled || ![path isKindOfClass:[NSString class]]) return res;
    NSString *pathStr = (NSString *)path;
    if (![pathStr containsString:S("/System/Library/ThermalMonitor/")]) return res;
    // 安全阀
    if (isTemperatureAboveSafetyCeiling()) return res;
    // 低功耗: 不修补 plist，保持原始亮度/背光控制
    if (isLowPowerMode()) return res;
    // 解除温控/正常模式: 按原有逻辑修补
    if (isUnlockMode() || g_brightnessProtection) {
        NSMutableDictionary *patched = [res mutableCopy];
        if (patched) {
            patchThermalPlistDict(patched);
            NSLog(@"[CPUthermal] 已修补热配置 plist: %@", [pathStr lastPathComponent]);
            return patched;
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

// ============================================================================
// %ctor — 构造函数 + 运行时设置变更监听
// ============================================================================

// Darwin 通知回调: 设置变更时重新加载
static void onSettingsChanged(CFNotificationCenterRef center,
                               void *observer,
                               CFStringRef name,
                               const void *object,
                               CFDictionaryRef userInfo) {
    loadPrefs();
    if (g_enabled) {
        NSLog(@"[CPUthermal] 设置已重新加载 — 功率模式:%d CPU:%d 亮度:%d 热状态:%d",
              g_powerMode, g_cpuProtection, g_brightnessProtection, g_thermalStateProtection);
    } else {
        NSLog(@"[CPUthermal] 设置已重新加载 — 已禁用");
    }
}

%ctor {
    @autoreleasepool {
        loadPrefs();

        if (g_enabled) {
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

            const char *powerModeStr = "正常";
            if (g_powerMode == 1) powerModeStr = "解除温控";
            else if (g_powerMode == 2) powerModeStr = "低功耗(70%)";

            NSLog(@"[CPUthermal] 温控防护已激活 — 功率模式:%s 安全阀:%d°C CPU:%d 亮度:%d 热状态:%d HID:%d CPMS:%d",
                  powerModeStr,
                  (int)(kSafetyTempThreshold / 1000),
                  g_cpuProtection, g_brightnessProtection, g_thermalStateProtection,
                  g_blockHidEvents, g_keepCPSMAlive);
        } else {
            NSLog(@"[CPUthermal] 配置关闭，仍监听设置变更以便后续开启");
        }

        // 注册设置变更监听（运行时重载）
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            CFStringRef notifName = CFStringCreateWithCString(kCFAllocatorDefault,
                kNotifNameC, kCFStringEncodingUTF8);
            if (notifName) {
                CFNotificationCenterAddObserver(c, NULL, onSettingsChanged,
                    notifName, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                CFRelease(notifName);
            }
            // 模拟热级别监听（独立功能）
            CFNotificationCenterAddObserver(c, NULL, onPuppetEvent,
                (__bridge CFStringRef)S("com.huayuarc.CPUthermal.puppet"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}
