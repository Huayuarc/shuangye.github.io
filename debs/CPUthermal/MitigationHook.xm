//
//  MitigationHook.xm — CPUthermal 集成版 v3（禁止系统高温停充 + 电池温控屏蔽）
//
//  v3（依据真机 IOKit IOPMPowerSource dump 校准，pasted_DE4F2BCF.txt）：
//   * 实测校准温度单位/量级：该节点 Temperature=3839 / VirtualTemperature=3839，
//     是 ×100 的百分之一摄氏度（=38.39°C）；历史 iOS 部分设备为 ×10。
//     因此归一按【量级分档】，任何分位都被写成安全 ~25.0°C，杜绝单位错判：
//        原值>=1000 → ×100 → 写 2500(=25.00°C)
//        60<=原值<1000 → ×10 → 写 250(=25.0°C)
//        原值<60 → ℃ → 写 25
//   * 关键因果链（dump 证实）：
//        Temperature/VirtualTemperature   （热判依据，顶层）
//              ↓ powerd 认定过热
//        ChargerData { NotChargingReason:256; ChargingCurrent:0;
//                      TimeChargingThermallyLimited:304; ChargerID:-1 }
//        即 IsCharging:0 + ExternalConnected:1 + ExternalChargeCapable:1，
//        却 Amperage:0 —— 典型"电源就绪但拒不充电"。根因是热停充。
//     因此本模块：
//        (1) 递归清洗（含嵌套 ChargerData{BatteryData{...}} 子 dict）：温度分档归一、
//            不充原因码(NotChargingReason/256 等)归 0、暂停布尔归 false；
//        (2) 重新校准单值+整本批量读双路 hook，让 thermal & CallAssist 都读不到热度；
//        (3) 对 ChargerData/顶层 ChargingCurrent 被写 0 的低电流上限，保留原上限重放，
//            避免恢复无门。
//   * 本模块仍【仅 powerd】，thermalmonitord CPU/ObjC 由 Tweak.x 接管，不重复 Hook，
//     规避同进程 IORegistryEntrySetCFProperty 双 Hook（1.6.4-74 教训）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <substrate.h>
#import <CoreFoundation/CoreFoundation.h>

#define NOTIFY_CPU_MODE "com.huayuarc.cputhermal/mitigationState"

// 归一目标温度（分位自适应后落到 ~25°C）
static const int NeutralC    = 25;    // ℃  格式
static const int NeutralC10  = 250;   // ×10 格式（25.0°C）
static const int NeutralC100 = 2500;  // ×100 格式（25.00°C）
static const int SafeCurrentMA = 5000;
static int gToken = -1;

typedef mach_port_t io_registry_entry_t;

extern "C" kern_return_t IORegistryEntrySetCFProperty(io_registry_entry_t entry, CFStringRef propertyName, CFTypeRef property);
extern "C" kern_return_t IORegistryEntryCreateCFProperties(io_registry_entry_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options);
extern "C" CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options);

static kern_return_t (*orig_RegSetCFProp)(io_registry_entry_t, CFStringRef, CFTypeRef) = NULL;
static CFTypeRef      (*orig_SingleCreateProp)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t) = NULL;
static kern_return_t (*orig_MultiCreateProps)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t) = NULL;

// ---- key 集（实测名） ----
static NSArray<NSString *> *kTempKeys;     // 温度类（含顶层）
static NSArray<NSString *> *kTempNestedHints; // 出现在嵌套 BatteryData/LifetimeData 里的同义词（保守也归一）
static NSArray<NSString *> *kPauseKeys;    // 停充/暂停布尔
static NSArray<NSString *> *kReasonKeys;   // "不充原因码"整数 → 0（含 ChargerData.NotChargingReason）
static NSArray<NSString *> *kLimitKeys;    // 充电电流上限（低值重放）

static void initKeySets(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kTempKeys       = @[ @"Temperature", @"VirtualTemperature", @"BatteryTemperature" ];
        kTempNestedHints= @[ @"AverageTemperature", @"MinimumTemperature", @"MaximumTemperature" ];
        kPauseKeys      = @[ @"ChargingPaused", @"ChargeInhibit", @"ChargeBlocked",
                             @"BatteryChargingInterrupted", @"BatteryChargingInterruptedCount",
                             @"ChargingCriticalTemperature", @"ForceDisableCharge" ];
        kReasonKeys     = @[ @"NotChargingReason", @"BatteryNotChargingReason",
                             @"ChargeStateReason", @"ChargingLimitReasonCode" ];
        kLimitKeys      = @[ @"ChargeCurrentLimit", @"ExternalChargeCurrentLimit",
                             @"ChargingCurrent", @"MaxChargeCurrent", @"NominalChargeCurrent",
                             @"AppleSmartBatteryMaxCurrent", @"ConfiguredChargeCurrent" ];
    });
}

static BOOL chargeProtectOn(void) {
    if (gToken == -1) notify_register_check(NOTIFY_CPU_MODE, &gToken);
    uint64_t s = 0;
    notify_get_state(gToken, &s);
    return ((s >> 10) & 1) || ((s >> 9) & 1);   // bit10 禁止高温停充 / bit9 满血快充
}

static BOOL keyHit(NSString *k, NSArray<NSString *> *keys) {
    for (NSString *c in keys)
        if ([k rangeOfString:c options:NSCaseInsensitiveSearch|NSLiteralSearch].location != NSNotFound)
            return YES;
    return NO;
}

#pragma mark - 温度分档归一（返回替换值，NULL 表示不改）
static CFNumberRef neutralizedTempFor(CFNumberRef origNum) {
    int v = 0;
    if (!CFNumberGetValue(origNum, kCFNumberSInt32Type, &v)) return NULL;
    int write;
    if      (v >= 1000) write = NeutralC100; // ×100 分位
    else if (v >= 60)   write = NeutralC10;   // ×10  分位
    else                write = NeutralC;     // ℃
    // 已是安全温则不动（避免无谓抖动）
    if (write == 2500) { if (v < 2600 && v > 2300) return NULL; }
    else if (write == 250) { if (v < 260 && v > 230) return NULL; }
    else { if (v >= 20 && v <= 32) return NULL; }
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &write);
    return n;
}

#pragma mark - 递归清洗：CF deep-sanitize（返回 create 规则：须由调用方 CFRelease＝参考计数+1）
// 输入可以是 CFDictionary / CFArray / 基础 CFType。为安全，深度不可变容器全部重建。
static CFTypeRef sanitizeNode(CFTypeRef node) {
    if (!node) return NULL;
    CFTypeID tid = CFGetTypeID(node);

    if (tid == CFDictionaryGetTypeID()) {
        CFDictionaryRef d = (CFDictionaryRef)node;
        // 重建 dict（保序不重要）
        CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, CFDictionaryGetCount(d),
                                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFIndex n = CFDictionaryGetCount(d);
        CFStringRef *keys = (CFStringRef *)calloc(n ? (size_t)n : 1, sizeof(CFStringRef));
        CFTypeRef   *vals = (CFTypeRef   *)calloc(n ? (size_t)n : 1, sizeof(CFTypeRef));
        CFDictionaryGetKeysAndValues(d, (const void **)keys, (const void **)vals);
        for (CFIndex i = 0; i < n; i++) {
            NSString *kn = (__bridge NSString *)keys[i];
            // 温度键：任意递归层 → 分档归一
            if (keyHit(kn, kTempKeys) || keyHit(kn, kTempNestedHints)) {
                if (vals[i] && CFGetTypeID(vals[i]) == CFNumberGetTypeID()) {
                    CFNumberRef nu = neutralizedTempFor((CFNumberRef)vals[i]);
                    if (nu) { CFDictionarySetValue(out, keys[i], nu); CFRelease(nu); continue; }
                }
                // 非数值温度值（罕见）一律放行原值
                CFTypeRef sub = sanitizeNode(vals[i]);
                CFDictionarySetValue(out, keys[i], sub ?: vals[i]);
                if (sub && sub != vals[i]) CFRelease(sub);
                continue;
            }
            // 不充原因码 → 0
            if (keyHit(kn, kReasonKeys) && vals[i] && CFGetTypeID(vals[i]) == CFNumberGetTypeID()) {
                int zero = 0;
                CFNumberRef zz = CFNumberCreate(NULL, kCFNumberIntType, &zero);
                CFDictionarySetValue(out, keys[i], zz);
                CFRelease(zz);
                continue;
            }
            // 暂停布尔 → NO
            if (keyHit(kn, kPauseKeys) && vals[i] && CFGetTypeID(vals[i]) == CFBooleanGetTypeID()) {
                CFDictionarySetValue(out, keys[i], kCFBooleanFalse);
                continue;
            }
            // 电流上限类（数字）若目标是 0 且外部可充 → 偏向放行+交给写侧兜底：此处不硬改，
            // 由 hook_SetCFProperty 统一处理真实写入；读侧仅清指标字段以免 UI 误导。
            CFTypeRef sub = sanitizeNode(vals[i]);
            CFDictionarySetValue(out, keys[i], sub ?: vals[i]);
            if (sub && sub != vals[i]) CFRelease(sub);
        }
        free(keys); free(vals);
        return out;
    }
    if (tid == CFArrayGetTypeID()) {
        CFArrayRef a = (CFArrayRef)node;
        CFMutableArrayRef out = CFArrayCreateMutable(NULL, CFArrayGetCount(a),
                                      &kCFTypeArrayCallBacks);
        CFIndex n = CFArrayGetCount(a);
        for (CFIndex i = 0; i < n; i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(a, i);
            CFTypeRef sub = sanitizeNode(item);
            CFArrayAppendValue(out, sub ?: item);
            if (sub && sub != item) CFRelease(sub);
        }
        return out;
    }
    return NULL; // 叶子原样（返回 NULL，调用侧保留原 value）
}

static void cleanBulkOut(CFMutableDictionaryRef *properties) {
    if (!properties || !*properties) return;
    CFTypeRef cleaned = sanitizeNode(*properties);
    if (!cleaned) return;
    CFRelease(*properties);
    *properties = (CFMutableDictionaryRef)cleaned;
}

#pragma mark - 读边界 hook

static CFTypeRef hook_SingleCreateProp(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) {
    if (key && chargeProtectOn()) {
        NSString *k = (__bridge NSString *)key;
        if (keyHit(k, kTempKeys)) {
            // 单属性读按顶层实测 ×100 语义给安全温 25.00°C；bulk 仍为主路径递归清洗
            int v = NeutralC100;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
        }
        if (keyHit(k, kReasonKeys)) {
            int z = 0;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &z);
        }
        if (keyHit(k, kPauseKeys)) {
            return (CFTypeRef)CFRetain(kCFBooleanFalse);
        }
    }
    return orig_SingleCreateProp ? orig_SingleCreateProp(entry, key, allocator, options) : NULL;
}

static kern_return_t hook_MultiCreateProps(io_registry_entry_t entry, CFMutableDictionaryRef *properties,
                                           CFAllocatorRef allocator, uint32_t options) {
    if (!orig_MultiCreateProps) return properties && !*properties ? KERN_FAILURE : (kern_return_t)0;
    kern_return_t r = orig_MultiCreateProps(entry, properties, allocator, options);
    if (r == KERN_SUCCESS && properties && *properties && chargeProtectOn())
        cleanBulkOut(properties);           // 递归：温度/原因/暂停全部清洗
    return r;
}

#pragma mark - 写边界 hook（停充/原因/降流）

static int readNodeMaxAdjacent(io_registry_entry_t entry) {
    CFMutableDictionaryRef props = NULL;
    // 用未被 hook 的 orig 指针，避免在已 Hook 函数内再次自递归
    if (orig_MultiCreateProps &&
        orig_MultiCreateProps(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
        // 顶层或 ChargerData 子dict里找原机上限
        int max = 0;
        for (NSString *k in kLimitKeys) {
            CFTypeRef v = CFDictionaryGetValue(props, (__bridge CFStringRef)k);
            if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                int t = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &t);
                if (t > max) max = t;
            }
        }
        // ChargerData 子dict
        CFTypeRef cd = CFDictionaryGetValue(props, CFSTR("ChargerData"));
        if (cd && CFGetTypeID(cd) == CFDictionaryGetTypeID())
            for (NSString *k in kLimitKeys) {
                CFTypeRef v = CFDictionaryGetValue((CFDictionaryRef)cd, (__bridge CFStringRef)k);
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

static kern_return_t hook_SetCFProp(io_registry_entry_t entry, CFStringRef propertyName, CFTypeRef property) {
    if (!propertyName) return orig_RegSetCFProp ? orig_RegSetCFProp(entry, propertyName, property) : KERN_FAILURE;
    if (!chargeProtectOn()) return orig_RegSetCFProp ? orig_RegSetCFProp(entry, propertyName, property) : KERN_FAILURE;

    NSString *prop = (__bridge NSString *)propertyName;

    if (keyHit(prop, kPauseKeys))   // 停充/暂停布尔 → NO
        return orig_RegSetCFProp(entry, propertyName, kCFBooleanFalse);

    if (CFGetTypeID(property) == CFNumberGetTypeID() && keyHit(prop, kReasonKeys)) { // 原因码 →0
        int z = 0; CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &z);
        kern_return_t r = orig_RegSetCFProp(entry, propertyName, n); CFRelease(n); return r;
    }

    if (CFGetTypeID(property) == CFNumberGetTypeID() && keyHit(prop, kLimitKeys)) { // 电流→0 重放原上限
        int val = 0; CFNumberGetValue((CFNumberRef)property, kCFNumberIntType, &val);
        if (val <= 0) {
            int max = readNodeMaxAdjacent(entry);
            if (max <= 0) max = SafeCurrentMA;
            CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &max);
            kern_return_t r = orig_RegSetCFProp(entry, propertyName, n); CFRelease(n); return r;
        }
    }
    return orig_RegSetCFProp ? orig_RegSetCFProp(entry, propertyName, property) : KERN_FAILURE;
}

#pragma mark - ctor
%ctor {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![[NSProcessInfo processInfo].processName isEqualToString:@"powerd"]) return;
        initKeySets();

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!iokit) return;
        void *pWrite = dlsym(iokit, "IORegistryEntrySetCFProperty");
        void *pSingle= dlsym(iokit, "IORegistryEntryCreateCFProperty");
        void *pMulti = dlsym(iokit, "IORegistryEntryCreateCFProperties");
        if (!pWrite || !pMulti) return;

        if (pWrite)  MSHookFunction(pWrite,  (void*)hook_SetCFProp,        (void**)&orig_RegSetCFProp);
        if (pMulti)  MSHookFunction(pMulti,  (void*)hook_MultiCreateProps, (void**)&orig_MultiCreateProps);
        if (pSingle) MSHookFunction(pSingle, (void*)hook_SingleCreateProp, (void**)&orig_SingleCreateProp);
    });
}
