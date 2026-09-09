//
//  MitigationHook.xm — CPUthermal 工程集成版（禁止系统高温停充/高温停充保护）
//
//  说明（相对独立版的重要调整）：
//  - 本工程 Tweak.x 已在 thermalmonitord 完整接管 CPU 频率、热压力、防暗屏、
//    backlightComponentControl 与 IOKit 读写边界（IOServiceSetProperty /
//    IORegistryEntrySetCFProperty / SetCFProperties）。为避免同一进程内两个
//    dylib 双 Hook IORegistryEntrySetCFProperty 造成拦截打架（1.6.4-74 曾因此
//    出现 CPU_Ceiling 恢复被吞写的根因），本集成版【不再】复刻：
//       * ObjC 层  %hook MitigationController（已由 Tweak.x 接管）
//       * CPU_Ceiling / p-state-cap / CPU_Floor 的 IOKit 写钳制
//       * 亮度/热降光拦截 与 ObjC 禁用（已由 Tweak.x 的 CommonProduct 层处理）
//  - 本模块专注当前工程尚缺失、且只在 powerd 出现的能力：
//       ★ 禁止系统高温停充（热->停充/暂停->电流写到0 整条链路撤销）
//       ★ 高温降流上限恢复（宁可高不可 0）
//       ★ 电池温度读取归一 32℃，让 powerd 无法凭“读高温”发起停充
//       ★ "不充原因码"清零（0x8010 / BatteryNotChargingReason 一类）
//  - notify 状态：与独立版保持一致，面板通过 CPUthermalPaths.h 的
//       CPUthermalPostMitigationChargeProtect(BOOL) 同步 bit10。
//       进程内以 notify_get_state 读 bit10（=禁止高温停充），并兼容 bit9（满血）。
//       bit9 可由其它开关另发，这里仅作为 OR 之一。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <substrate.h>
#import <CoreFoundation/CoreFoundation.h>

#define NOTIFY_CPU_MODE "com.huayuarc.cputhermal/mitigationState"

static const CFIndex ThermalNeutralCelsius = 32; // 归一温度（沿用实测 32°C）
static const int     SafeCurrentMA        = 5000; // 电流兜底（仅节点读不到上限时才用）
static int gToken = -1;

typedef mach_port_t io_registry_entry_t;

extern "C" kern_return_t IORegistryEntrySetCFProperty(io_registry_entry_t entry, CFStringRef propertyName, CFTypeRef property);
extern "C" kern_return_t IORegistryEntryCreateCFProperties(io_registry_entry_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options);

static kern_return_t (*orig_RegSetCFProp)(io_registry_entry_t, CFStringRef, CFTypeRef) = NULL;
static CFTypeRef     (*orig_RegCreateCFProp)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t) = NULL;

// ---- key 集 ----
static NSArray<NSString *> *kTempKeys;     // 温度读 key（在 powerd 归一）
static NSArray<NSString *> *kPauseKeys;    // 停充/暂停布尔 → 钳 NO
static NSArray<NSString *> *kReasonKeys;   // 整型"不充原因码" → 抹 0
static NSArray<NSString *> *kLimitKeys;    // 充电电流上限 → 低值/0 重放节点原生

static void initKeySets(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kTempKeys    = @[ @"Temperature", @"VirtualTemperature",
                          @"BatteryTemperature", @"InternalTemperature", @"DieTemperature" ];
        kPauseKeys   = @[ @"ChargingPaused", @"ChargeInhibit", @"ChargeBlocked",
                          @"BatteryChargingInterrupted", @"BatteryChargingInterruptedCount",
                          @"ChargingCriticalTemperature", @"ForceDisableCharge" ];
        kReasonKeys  = @[ @"BatteryNotChargingReason", @"NotChargingReason",
                          @"ChargeStateReason", @"ChargingLimitReasonCode" ];
        kLimitKeys   = @[ @"ChargeCurrentLimit", @"ExternalChargeCurrentLimit",
                          @"MaxChargeCurrent", @"NominalChargeCurrent",
                          @"AppleSmartBatteryMaxCurrent", @"ConfiguredChargeCurrent" ];
    });
}

static BOOL chargeProtectOn(void) {
    if (gToken == -1) notify_register_check(NOTIFY_CPU_MODE, &gToken);
    uint64_t s = 0;
    notify_get_state(gToken, &s);
    // bit10=禁止高温停充；bit9=满血快充——二者任一开启即拦截热停充
    return ((s >> 10) & 1) || ((s >> 9) & 1);
}

static BOOL strHit(NSString *prop, NSArray<NSString *> *keys) {
    for (NSString *k in keys)
        if ([prop rangeOfString:k options:NSCaseInsensitiveSearch|NSLiteralSearch].location != NSNotFound)
            return YES;
    return NO;
}

#pragma mark - powerd：温度读取归一（阻断“热判”→停充的决策源头）
static CFTypeRef hook_CreateCFProperty(io_registry_entry_t entry, CFStringRef key,
                                       CFAllocatorRef allocator, uint32_t options) {
    if (key && chargeProtectOn()) {
        NSString *k = (__bridge NSString *)key;
        if (strHit(k, kTempKeys)) {
            CFIndex c = ThermalNeutralCelsius;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &c); // caller 负责释放
        }
    }
    return orig_RegCreateCFProp ? orig_RegCreateCFProp(entry, key, allocator, options) : NULL;
}

#pragma mark - powerd：高温停充/降流的落点拦截
static int readNodeMaxCurrentMA(io_registry_entry_t entry) {
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
        int max = 0;
        for (NSString *k in kLimitKeys) {
            CFTypeRef v = CFDictionaryGetValue(props, (__bridge CFStringRef)k);
            if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                int t = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &t);
                if (t > max) max = t;
            }
        }
        CFRelease(props);
        if (max > 0) return max;
    }
    return 0;
}

static kern_return_t hook_SetCFProperty(io_registry_entry_t entry, CFStringRef propertyName, CFTypeRef property) {
    if (!propertyName) return orig_RegSetCFProp(entry, propertyName, property);
    if (!chargeProtectOn()) return orig_RegSetCFProp(entry, propertyName, property);

    NSString *prop = (__bridge NSString *)propertyName;

    // (a) 停充/暂停/过热阻断布尔位 → 强制放行充电（写 NO）
    if (strHit(prop, kPauseKeys))
        return orig_RegSetCFProp(entry, propertyName, kCFBooleanFalse);

    // (b) 整型"不充原因码" → 抹 0（清 0x8010 健康/热原因）
    if (CFGetTypeID(property) == CFNumberGetTypeID() && strHit(prop, kReasonKeys)) {
        int z = 0;
        CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &z);
        kern_return_t r = orig_RegSetCFProp(entry, propertyName, n);
        CFRelease(n);
        return r;
    }

    // (c) 高温降流/停充把电流上限写成 0 或负 → 重放节点原机上限；正常限流尊重系统
    if (CFGetTypeID(property) == CFNumberGetTypeID() && strHit(prop, kLimitKeys)) {
        int val = 0;
        CFNumberGetValue((CFNumberRef)property, kCFNumberIntType, &val);
        if (val <= 0) {
            int max = readNodeMaxCurrentMA(entry);
            if (max <= 0) max = SafeCurrentMA;
            CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &max);
            kern_return_t r = orig_RegSetCFProp(entry, propertyName, n);
            CFRelease(n);
            return r;
        }
    }

    return orig_RegSetCFProp(entry, propertyName, property);
}

#pragma mark - ctor
%ctor {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *proc = [NSProcessInfo processInfo].processName;
        // 本模块只在 powerd 生效；在 thermalmonitord 内不重复 CPU 频率/ObjC 拦截（Tweak.x 已接管，
        // 且要避免同进程对 IORegistryEntrySetCFProperty 的双 Hook 冲突）。
        if (![proc isEqualToString:@"powerd"]) return;

        initKeySets();

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!iokit) return;

        void *pSet = dlsym(iokit, "IORegistryEntrySetCFProperty");
        void *pRead = dlsym(iokit, "IORegistryEntryCreateCFProperty");
        if (!pSet) return;

        MSHookFunction(pSet, (void*)hook_SetCFProperty, (void**)&orig_RegSetCFProp);
        if (pRead)
            MSHookFunction(pRead, (void*)hook_CreateCFProperty, (void**)&orig_RegCreateCFProp);
    });
}
