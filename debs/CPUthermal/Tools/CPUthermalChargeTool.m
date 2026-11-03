#import <Foundation/Foundation.h>
#include <spawn.h>
#include <sys/wait.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <os/log.h>
#import <signal.h>
#import <stdint.h>
#import <string.h>
#import <unistd.h>
#import <CPUthermalPaths.h>
#import <CPUthermalCompat.h>

#define kIOMasterPortDefault MACH_PORT_NULL
extern kern_return_t CPUthermalIORegistryEntrySetCFProperties(io_registry_entry_t, CFTypeRef) __asm("_IORegistryEntrySetCFProperties");
extern kern_return_t CPUthermalIORegistryEntrySetCFProperty(io_registry_entry_t, CFStringRef, CFTypeRef) __asm("_IORegistryEntrySetCFProperty");

static os_log_t CPUHardwareLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.huayuarc.cputhermal", "cpu-hardware"); });
    return log;
}

static kern_return_t SetCPUProperty(const char *serviceName, CFStringRef key, int32_t value) {
    if (!serviceName || !key) return KERN_INVALID_ARGUMENT;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(serviceName));
    if (service == IO_OBJECT_NULL) {
        os_log_error(CPUHardwareLog(), "service missing: %{public}s", serviceName);
        return KERN_NOT_FOUND;
    }
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    kern_return_t result = number ? CPUthermalIORegistryEntrySetCFProperty(service, key, number) : KERN_RESOURCE_SHORTAGE;
    CFTypeRef readback = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    int32_t actual = INT32_MIN;
    BOOL readable = readback && CFGetTypeID(readback) == CFNumberGetTypeID() &&
                    CFNumberGetValue((CFNumberRef)readback, kCFNumberSInt32Type, &actual);
    os_log(CPUHardwareLog(), "set service=%{public}s key=%{public}@ value=%d kr=%d readback=%d readable=%d",
           serviceName, key, value, result, actual, readable);
    if (readback) CFRelease(readback);
    if (number) CFRelease(number);
    IOObjectRelease(service);
    return result;
}

static void ApplyIndependentCPUMode(NSDictionary *prefs) {
    NSString *mode = [prefs[S("powerMode")] isKindOfClass:[NSString class]] ? prefs[S("powerMode")] : S("fullPower");
    BOOL lowPower = [mode isEqualToString:S("lowPower")];
    // AppleCLPC 的动态功率目标是 Q24 瓦特；-1.0 (0xff000000) 表示不限制。
    const int32_t unrestrictedQ24 = (int32_t)0xff000000;
    const int32_t lowPowerQ24 = (int32_t)(2.5 * 16777216.0);
    const int32_t target = lowPower ? lowPowerQ24 : unrestrictedQ24;
    SetCPUProperty("AppleCLPC", CFSTR("`pkg-low-power-target"), target);
    SetCPUProperty("AppleCLPC", CFSTR("`pkg-avg-therm-power-target"), target);
}

// ChargeLimiter 电量阈值核心移植：SmartBatteryAPI + 智能停充 + 停充自动禁流。
// 不处理温度阈值、通知、统计、充电电流和附加动作。
static BOOL gOwnsInhibit = NO;
static BOOL gOwnsInflowDisable = NO;
static BOOL gOwnershipPreferSmart = YES;
static int gNotifyToken = 0;

static BOOL BoolPreference(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSInteger IntegerPreference(NSDictionary *prefs, NSString *key, NSInteger fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static void LoadOwnership(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    gOwnsInhibit = [prefs[S("__smartChargeOwnsInhibit")] boolValue];
    gOwnsInflowDisable = [prefs[S("__smartChargeOwnsInflowDisable")] boolValue];
    id source = prefs[S("__smartChargeOwnershipPreferSmart")];
    gOwnershipPreferSmart = [source respondsToSelector:@selector(boolValue)] ? [source boolValue] : YES;
}

static void SaveOwnership(void) {
    // 读取失败时绝不写回：否则会写出只含本模块键的字典，把 powerMode 等其它偏好一并抹掉
    // （曾导致“界面低功耗、频率却恢复到满血”）。
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs();
    if (!prefs || prefs.count == 0) return;
    if (gOwnsInhibit) prefs[S("__smartChargeOwnsInhibit")] = @YES;
    else [prefs removeObjectForKey:S("__smartChargeOwnsInhibit")];
    if (gOwnsInflowDisable) prefs[S("__smartChargeOwnsInflowDisable")] = @YES;
    else [prefs removeObjectForKey:S("__smartChargeOwnsInflowDisable")];
    if (gOwnsInhibit || gOwnsInflowDisable) prefs[S("__smartChargeOwnershipPreferSmart")] = @(gOwnershipPreferSmart);
    else [prefs removeObjectForKey:S("__smartChargeOwnershipPreferSmart")];
    CPUthermalWritePrefs(prefs);
}

static io_service_t BatteryService(BOOL preferSmart) {
    io_service_t service = IO_OBJECT_NULL;
    if (preferSmart)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service == IO_OBJECT_NULL)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    if (service == IO_OBJECT_NULL && !preferSmart)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    return service;
}

static NSDictionary *BatteryProperties(io_service_t service) {
    if (service == IO_OBJECT_NULL) return nil;
    CFMutableDictionaryRef raw = NULL;
    if (IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) != KERN_SUCCESS || !raw) return nil;
    return CFBridgingRelease(raw);
}

static BOOL AdapterConnected(NSDictionary *properties) {
    NSDictionary *adapter = [properties[S("AdapterDetails")] isKindOfClass:[NSDictionary class]] ? properties[S("AdapterDetails")] : nil;
    NSString *description = [adapter[S("Description")] isKindOfClass:[NSString class]] ? adapter[S("Description")] : nil;
    if (adapter.count && ![description isEqualToString:S("batt")]) return YES;
    return [properties[S("ExternalConnected")] boolValue] || [properties[S("ExternalChargeCapable")] boolValue];
}

static BOOL SetProperties(BOOL preferSmart, NSDictionary *properties) {
    io_service_t service = BatteryService(preferSmart);
    if (service == IO_OBJECT_NULL) return NO;
    kern_return_t result = CPUthermalIORegistryEntrySetCFProperties(service, (__bridge CFTypeRef)properties);
    IOObjectRelease(service);
    return result == KERN_SUCCESS;
}

static BOOL SetChargeInhibited(BOOL preferSmart, BOOL inhibited) {
    BOOL ok = SetProperties(preferSmart, @{S("PredictiveChargingInhibit"):@(inhibited)});
    if (ok) { if (inhibited) gOwnershipPreferSmart = preferSmart; gOwnsInhibit = inhibited; SaveOwnership(); }
    return ok;
}

static BOOL SetInflowEnabled(BOOL preferSmart, BOOL enabled) {
    BOOL ok = SetProperties(preferSmart, @{S("ExternalConnected"):@(enabled)});
    if (ok) { if (!enabled) gOwnershipPreferSmart = preferSmart; gOwnsInflowDisable = !enabled; SaveOwnership(); }
    return ok;
}

static void RestoreOwnedState(void) {
    BOOL preferSmart = gOwnershipPreferSmart;
    if (gOwnsInflowDisable) SetInflowEnabled(preferSmart, YES);
    if (gOwnsInhibit) SetChargeInhibited(preferSmart, NO);
}

static void EvaluateBattery(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    // 独立 root 执行器：模式通知与 15 秒定时器都会重申 CPU PPM/CLPC 状态，
    // 不依赖 thermalmonitord 的 tweak 注入是否被 RootHide 接纳。
    ApplyIndependentCPUMode(prefs);
    // isolation.23：单一总开关。旧键 smartChargeUseSmartBatteryAPI / smartChargeDisableInflow
    // 已合并进面板的“SmartBatteryAPI 智能停充”总开关，功能不变——总开关开启时默认启用
    // SmartBattery 优先 + 停充自动禁流（等同旧三开关同时为 YES）。
    // 旧键若仍存在于 plist（用户此前用过旧面板并显式写成 NO），按旧意图继续生效。
    BOOL enabled = BoolPreference(prefs, S("smartChargeEnabled"), NO);
    BOOL preferSmart = BoolPreference(prefs, S("smartChargeUseSmartBatteryAPI"), YES);
    BOOL disableInflow = BoolPreference(prefs, S("smartChargeDisableInflow"), YES);
    if ((gOwnsInhibit || gOwnsInflowDisable) && preferSmart != gOwnershipPreferSmart) RestoreOwnedState();
    if (!enabled) { RestoreOwnedState(); return; }

    io_service_t service = BatteryService(preferSmart);
    NSDictionary *properties = BatteryProperties(service);
    if (!properties) { if (service != IO_OBJECT_NULL) IOObjectRelease(service); return; }
    NSInteger stopLevel = MAX(70, MIN(100, IntegerPreference(prefs, S("smartChargeStopLevel"), 80)));
    NSInteger resumeLevel = MAX(5, stopLevel - 5);
    NSInteger capacity = IntegerPreference(properties, S("CurrentCapacity"), -1);
    BOOL connected = AdapterConnected(properties);
    IOObjectRelease(service);

    if (capacity < 0 || !connected) return;
    if (capacity >= stopLevel) {
        if (!gOwnsInhibit) SetChargeInhibited(preferSmart, YES);
        if (disableInflow && !gOwnsInflowDisable) SetInflowEnabled(preferSmart, NO);
        if (!disableInflow && gOwnsInflowDisable) SetInflowEnabled(preferSmart, YES);
    } else if (capacity <= resumeLevel) {
        // ChargeLimiter 顺序：先恢复输入，再恢复充电。
        if (gOwnsInflowDisable) SetInflowEnabled(preferSmart, YES);
        if (gOwnsInhibit) SetChargeInhibited(preferSmart, NO);
    }
}
// AppleSmartBattery 的 Temperature 为百分之一摄氏度（4600 => 46.0℃），兼容十分之一
static BOOL ResetCharging(void) {
    RestoreOwnedState();
    return !gOwnsInhibit && !gOwnsInflowDisable;
}

static void SignalHandler(int signalNumber) {
    (void)signalNumber;
    ResetCharging();
    _exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        LoadOwnership();
        if (argc > 1 && strcmp(argv[1], "reset") == 0) return ResetCharging() ? 0 : 2;
        signal(SIGTERM, SignalHandler); signal(SIGINT, SignalHandler); signal(SIGHUP, SignalHandler);
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gNotifyToken, dispatch_get_main_queue(), ^(int token) {
            (void)token; @autoreleasepool { EvaluateBattery(); }
        });
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(__unused NSTimer *timer) {
            @autoreleasepool { EvaluateBattery(); }
        }];
        EvaluateBattery();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
