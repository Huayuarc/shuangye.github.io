#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <os/lock.h>
#import <CPUthermalPaths.h>
extern "C" kern_return_t IORegistryEntryGetRegistryEntryID(io_registry_entry_t entry, uint64_t *entryID);

// 强制满血快充 + 屏蔽电池充电温度检测（仅注入 powerd）。
// 目的：温度无关地持续恢复充电，绝不触碰 CPU/GPU 功耗，因此不会带来降频/降功耗。
// - 在 powerd 的电池属性读取边界把充电决策温度固定为 32°C；
// - 周期清除电池管理器的 ChargeInhibit，避免“温度过高导致的充电抑制”残留；
// - 不 Hook thermalmonitord、不修改任何 CPU/GPU/功率预算字段。

#define kNormalChargeTemperatureC 32

static _Atomic(bool) gTempBypassEnabled=false;   // 屏蔽电池充电温度检测
static _Atomic(bool) gForceFastChargeEnabled=false; // 强制满血快充（无视发热）
static int gSettingsToken=0;
static dispatch_source_t gChargeInhibitTimer=NULL;
static os_unfair_lock gBatteryEntryLock=OS_UNFAIR_LOCK_INIT;
static uint64_t gBatteryEntryIDs[8]={0};
static size_t gBatteryEntryCount=0;
static __thread BOOL gInternalRawRead=NO;

static void ReloadPrefs(NSDictionary *prefs) {
    atomic_store_explicit(&gTempBypassEnabled,[prefs[@"bypassBatteryChargeTemperature"] boolValue],memory_order_release);
    atomic_store_explicit(&gForceFastChargeEnabled,[prefs[@"forceFastChargeIgnoreHeat"] boolValue],memory_order_release);
}

static void RememberBatteryEntry(io_registry_entry_t entry);

// 电池服务：AppleSmartBattery → IOPMPowerSource → AppleARMPMUPowerSource
static io_service_t BatteryService(void) {
    io_service_t service=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("AppleSmartBattery"));
    if(service==IO_OBJECT_NULL)service=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("IOPMPowerSource"));
    if(service==IO_OBJECT_NULL)service=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("AppleARMPMUPowerSource"));
    if(service!=IO_OBJECT_NULL)RememberBatteryEntry(service);
    return service;
}

// 充电管理器：AppleSmartBatteryManager（含 ChargeInhibit / MaxChargeCurrent）
static io_service_t BatteryManagerService(void) {
    return IOServiceGetMatchingService(kIOMasterPortDefault,
        IOServiceMatching("AppleSmartBatteryManager"));
}

static BOOL IsBatteryProperties(CFDictionaryRef d) {
    if(!d)return NO;
    BOOL capacity=CFDictionaryContainsKey(d,CFSTR("CurrentCapacity"));
    BOOL identity=CFDictionaryContainsKey(d,CFSTR("ExternalConnected"))||
                  CFDictionaryContainsKey(d,CFSTR("BatteryInstalled"))||
                  CFDictionaryContainsKey(d,CFSTR("CycleCount"));
    return capacity&&identity;
}


static void RememberBatteryEntry(io_registry_entry_t entry) {
    uint64_t identifier=0; if(IORegistryEntryGetRegistryEntryID(entry,&identifier)!=KERN_SUCCESS||!identifier)return;
    os_unfair_lock_lock(&gBatteryEntryLock);
    for(size_t i=0;i<gBatteryEntryCount;i++)if(gBatteryEntryIDs[i]==identifier){os_unfair_lock_unlock(&gBatteryEntryLock);return;}
    if(gBatteryEntryCount<8)gBatteryEntryIDs[gBatteryEntryCount++]=identifier;
    os_unfair_lock_unlock(&gBatteryEntryLock);
}
static BOOL IsRememberedBatteryEntry(io_registry_entry_t entry) {
    uint64_t identifier=0; if(IORegistryEntryGetRegistryEntryID(entry,&identifier)!=KERN_SUCCESS||!identifier)return NO; BOOL found=NO;
    os_unfair_lock_lock(&gBatteryEntryLock);for(size_t i=0;i<gBatteryEntryCount;i++)if(gBatteryEntryIDs[i]==identifier){found=YES;break;}os_unfair_lock_unlock(&gBatteryEntryLock);return found;
}
static BOOL IsTemperatureKey(CFStringRef key) {
    return key&&(CFEqual(key,CFSTR("Temperature"))||CFEqual(key,CFSTR("VirtualTemperature"))||CFEqual(key,CFSTR("BatteryTemperature")));
}
static CFNumberRef NormalTemperatureNumber(void) { int value=kNormalChargeTemperatureC*100;return CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&value); }

static kern_return_t (*origCreateProperties)(io_registry_entry_t,CFMutableDictionaryRef*,CFAllocatorRef,IOOptionBits)=NULL;
static kern_return_t HookCreateProperties(io_registry_entry_t entry,CFMutableDictionaryRef *out,CFAllocatorRef allocator,IOOptionBits options) {
    kern_return_t result=origCreateProperties(entry,out,allocator,options);
    if(gInternalRawRead)return result;
    if(result!=KERN_SUCCESS||!out||!*out)return result;
    BOOL battery=IsBatteryProperties(*out);
    BOOL manager=CFDictionaryContainsKey(*out,CFSTR("ChargeInhibit"))||CFDictionaryContainsKey(*out,CFSTR("ChargeBlocked"));
    if(!battery&&!manager)return result;
    RememberBatteryEntry(entry);

    // 温度夹紧只在“屏蔽温度检测”明确开启时生效，且仅改温度读取结果，不影响功耗。
    if((atomic_load_explicit(&gTempBypassEnabled,memory_order_acquire)||atomic_load_explicit(&gForceFastChargeEnabled,memory_order_acquire))) {
        CFNumberRef normal=NormalTemperatureNumber();
        if(normal) {
            const CFStringRef keys[]={CFSTR("Temperature"),CFSTR("VirtualTemperature"),CFSTR("BatteryTemperature")};
            for(size_t i=0;i<sizeof(keys)/sizeof(keys[0]);i++)
                if(CFDictionaryContainsKey(*out,keys[i]))
                    CFDictionarySetValue(*out,keys[i],normal);
            CFRelease(normal);
        }
        for(NSString *key in @[S("ChargeInhibit"),S("ChargeBlocked"),S("ChargingPaused"),S("PredictiveChargingInhibit")])
            if(CFDictionaryContainsKey(*out,(__bridge CFStringRef)key))CFDictionarySetValue(*out,(__bridge CFStringRef)key,kCFBooleanFalse);
    }
    return result;
}

static CFTypeRef (*origCreateProperty)(io_registry_entry_t,CFStringRef,CFAllocatorRef,IOOptionBits)=NULL;
static CFTypeRef HookCreateProperty(io_registry_entry_t entry,CFStringRef key,CFAllocatorRef allocator,IOOptionBits options) {
    CFTypeRef value=origCreateProperty(entry,key,allocator,options);
    if(gInternalRawRead)return value;
    if(!(atomic_load_explicit(&gTempBypassEnabled,memory_order_acquire)||atomic_load_explicit(&gForceFastChargeEnabled,memory_order_acquire)))return value;
    BOOL uniqueKey=key&&(CFEqual(key,CFSTR("VirtualTemperature"))||CFEqual(key,CFSTR("BatteryTemperature")));
    if(IsTemperatureKey(key)&&(uniqueKey||IsRememberedBatteryEntry(entry))) { if(value)CFRelease(value);return NormalTemperatureNumber(); }
    if(key&&(CFEqual(key,CFSTR("ChargeInhibit"))||CFEqual(key,CFSTR("ChargeBlocked"))||CFEqual(key,CFSTR("ChargingPaused"))||CFEqual(key,CFSTR("PredictiveChargingInhibit")))) { if(value)CFRelease(value);return CFRetain(kCFBooleanFalse); }
    return value;
}

// 清除电池管理器的充电抑制位（ChargeInhibit=false）以及可达的充电暂停状态。
// SBCPUFloating“强制满血快充”等价实现：持续把 ChargeInhibit 清为 0，
// 使 powerd/热状态不再阻断充电。此函数不写任何功耗/频率字段。
static void ForceChargeEnable(void) {
    if(!(atomic_load_explicit(&gTempBypassEnabled,memory_order_acquire)||atomic_load_explicit(&gForceFastChargeEnabled,memory_order_acquire)))return;
    io_service_t manager=BatteryManagerService();
    if(manager!=IO_OBJECT_NULL) {
        CFMutableDictionaryRef raw=NULL; BOOL blocked=NO;
        gInternalRawRead=YES;kern_return_t managerRead=IORegistryEntryCreateCFProperties(manager,&raw,kCFAllocatorDefault,0);gInternalRawRead=NO;if(managerRead==KERN_SUCCESS&&raw){NSDictionary *p=CFBridgingRelease(raw);blocked=[p[@"ChargeInhibit"] boolValue]||[p[@"ChargeBlocked"] boolValue]||[p[@"ChargingPaused"] boolValue];}
        if(blocked){IORegistryEntrySetCFProperty(manager,CFSTR("ChargeInhibit"),kCFBooleanFalse);IORegistryEntrySetCFProperty(manager,CFSTR("ChargeBlocked"),kCFBooleanFalse);IORegistryEntrySetCFProperty(manager,CFSTR("ChargingPaused"),kCFBooleanFalse);}
        IOObjectRelease(manager);
    }
    io_service_t battery=BatteryService();
    if(battery!=IO_OBJECT_NULL) {
        CFMutableDictionaryRef raw=NULL; NSDictionary *p=nil;gInternalRawRead=YES;kern_return_t batteryRead=IORegistryEntryCreateCFProperties(battery,&raw,kCFAllocatorDefault,0);gInternalRawRead=NO;if(batteryRead==KERN_SUCCESS&&raw)p=CFBridgingRelease(raw);
        BOOL paused=[p[@"ChargeInhibit"] boolValue]||[p[@"ChargingPaused"] boolValue]||[p[@"PredictiveChargingInhibit"] boolValue];
        if(paused)IORegistryEntrySetCFProperties(battery,(__bridge CFTypeRef)@{@"ChargeInhibit":@NO,@"ChargingPaused":@NO,@"PredictiveChargingInhibit":@NO});
        IOObjectRelease(battery);
    }
}

// 周期任务：开启“强制满血快充”后每 2 秒清一次抑制位，抵消 powerd 周期性热决策。
static void StartChargeInhibitTimer(void) {
    if(gChargeInhibitTimer)return;
    dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(timer,dispatch_walltime(NULL,0),2.0*NSEC_PER_SEC,0.2*NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer,^{ForceChargeEnable();});
    dispatch_resume(timer);
    gChargeInhibitTimer=timer;
}

%ctor { @autoreleasepool {
    ReloadPrefs(CPUthermalReadPrefs()?:@{});
    io_service_t initialBattery=BatteryService();if(initialBattery!=IO_OBJECT_NULL)IOObjectRelease(initialBattery);
    if(atomic_load_explicit(&gTempBypassEnabled,memory_order_acquire)||atomic_load_explicit(&gForceFastChargeEnabled,memory_order_acquire))StartChargeInhibitTimer();

    // 偏好通知移到后台队列；用户切开关时立即生效，不阻塞 powerd 主线程。
    dispatch_queue_t queue=dispatch_queue_create("com.huayuarc.cputhermal.batterytemp.preferences",DISPATCH_QUEUE_SERIAL);
    notify_register_dispatch(kCPUthermalSettingsChangedNotifC,&gSettingsToken,queue,^(int token){(void)token;
        ReloadPrefs(CPUthermalReadPrefs()?:@{});
        io_service_t battery=BatteryService();if(battery!=IO_OBJECT_NULL)IOObjectRelease(battery);
        if(atomic_load_explicit(&gTempBypassEnabled,memory_order_acquire)||atomic_load_explicit(&gForceFastChargeEnabled,memory_order_acquire))StartChargeInhibitTimer();
    });

    void *iokit=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW|RTLD_GLOBAL);
    if(iokit){
        void *symbol=dlsym(iokit,"IORegistryEntryCreateCFProperties");
        if(symbol)MSHookFunction(symbol,(void *)HookCreateProperties,(void **)&origCreateProperties);
        void *single=dlsym(iokit,"IORegistryEntryCreateCFProperty");
        if(single)MSHookFunction(single,(void *)HookCreateProperty,(void **)&origCreateProperty);
    }
    // 注入后立即执行一次，让用户切到该开关时无需等首个 2 秒周期。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ForceChargeEnable();});
} }
