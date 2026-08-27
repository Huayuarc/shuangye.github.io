#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

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

static void ReloadPrefs(NSDictionary *prefs) {
    atomic_store_explicit(&gTempBypassEnabled,[prefs[@"bypassBatteryChargeTemperature"] boolValue],memory_order_release);
    atomic_store_explicit(&gForceFastChargeEnabled,[prefs[@"forceFastChargeIgnoreHeat"] boolValue],memory_order_release);
}

// 电池服务：AppleSmartBattery → IOPMPowerSource → AppleARMPMUPowerSource
static io_service_t BatteryService(void) {
    io_service_t service=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("AppleSmartBattery"));
    if(service==IO_OBJECT_NULL)service=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("IOPMPowerSource"));
    if(service==IO_OBJECT_NULL)service=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("AppleARMPMUPowerSource"));
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

static kern_return_t (*origCreateProperties)(io_registry_entry_t,CFMutableDictionaryRef*,CFAllocatorRef,IOOptionBits)=NULL;
static kern_return_t HookCreateProperties(io_registry_entry_t entry,CFMutableDictionaryRef *out,CFAllocatorRef allocator,IOOptionBits options) {
    kern_return_t result=origCreateProperties(entry,out,allocator,options);
    if(result!=KERN_SUCCESS||!out||!*out||!IsBatteryProperties(*out))return result;

    // 温度夹紧只在“屏蔽温度检测”明确开启时生效，且仅改温度读取结果，不影响功耗。
    if(atomic_load_explicit(&gTempBypassEnabled,memory_order_acquire)) {
        int normalTemperature=kNormalChargeTemperatureC*100;
        CFNumberRef normal=CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&normalTemperature);
        if(normal) {
            const CFStringRef keys[]={CFSTR("Temperature"),CFSTR("VirtualTemperature"),CFSTR("BatteryTemperature")};
            for(size_t i=0;i<sizeof(keys)/sizeof(keys[0]);i++)
                if(CFDictionaryContainsKey(*out,keys[i]))
                    CFDictionarySetValue(*out,keys[i],normal);
            CFRelease(normal);
        }
    }
    return result;
}

// 清除电池管理器的充电抑制位（ChargeInhibit=false）以及可达的充电暂停状态。
// SBCPUFloating“强制满血快充”等价实现：持续把 ChargeInhibit 清为 0，
// 使 powerd/热状态不再阻断充电。此函数不写任何功耗/频率字段。
static void ForceChargeEnable(void) {
    if(!atomic_load_explicit(&gForceFastChargeEnabled,memory_order_acquire))return;

    io_service_t manager=BatteryManagerService();
    if(manager!=IO_OBJECT_NULL) {
        IORegistryEntrySetCFProperty(manager,CFSTR("ChargeInhibit"),kCFBooleanFalse);
        IORegistryEntrySetCFProperty(manager,CFSTR("ChargeBlocked"),kCFBooleanFalse);
        IOObjectRelease(manager);
    }

    // 电池侧：确保充电重启位为 false、外部输入保持连接。
    io_service_t battery=BatteryService();
    if(battery!=IO_OBJECT_NULL) {
        NSDictionary *props=nil;
        CFMutableDictionaryRef properties=NULL;
        if(IORegistryEntryCreateCFProperties(battery,&properties,kCFAllocatorDefault,0)==KERN_SUCCESS&&properties) {
            props=CFBridgingRelease(properties);
        }
        BOOL cablePresent=NO;
        NSDictionary *adapter=props[@"AdapterDetails"];
        NSString *description=[adapter isKindOfClass:[NSDictionary class]]?adapter[@"Description"]:nil;
        if([adapter isKindOfClass:[NSDictionary class]]&&adapter.count&&![description isEqualToString:@"batt"])cablePresent=YES;
        if(props)cablePresent=cablePresent||[props[@"ExternalChargeCapable"] boolValue]||[props[@"ExternalConnected"] boolValue];

        NSMutableDictionary *values=[NSMutableDictionary dictionary];
        values[@"ChargeInhibit"]=@NO;
        values[@"ChargingPaused"]=@NO;
        values[@"PredictiveChargingInhibit"]=@NO;
        values[@"IsCharging"]=@YES;
        if(cablePresent)values[@"ExternalConnected"]=@YES;
        IORegistryEntrySetCFProperties(battery,(__bridge CFTypeRef)values);
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
    if(atomic_load_explicit(&gForceFastChargeEnabled,memory_order_acquire))StartChargeInhibitTimer();

    // 偏好通知移到后台队列；用户切开关时立即生效，不阻塞 powerd 主线程。
    dispatch_queue_t queue=dispatch_queue_create("com.huayuarc.cputhermal.batterytemp.preferences",DISPATCH_QUEUE_SERIAL);
    notify_register_dispatch(kCPUthermalSettingsChangedNotifC,&gSettingsToken,queue,^(int token){(void)token;
        ReloadPrefs(CPUthermalReadPrefs()?:@{});
        if(atomic_load_explicit(&gForceFastChargeEnabled,memory_order_acquire))StartChargeInhibitTimer();
    });

    void *iokit=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW|RTLD_GLOBAL);
    if(iokit){
        void *symbol=dlsym(iokit,"IORegistryEntryCreateCFProperties");
        if(symbol)MSHookFunction(symbol,(void *)HookCreateProperties,(void **)&origCreateProperties);
    }
    // 注入后立即执行一次，让用户切到该开关时无需等首个 2 秒周期。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ForceChargeEnable();});
} }
