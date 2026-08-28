#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

// 适配型“旁路供电”：只注入 powerd。达到阈值后暂停电池充电，但不切断
// ExternalConnected，让适配器继续为整机供电；回落 5% 或关闭时恢复。
static _Atomic(bool) gEnabled=false;
static _Atomic(int) gStopLevel=95;
static _Atomic(bool) gPaused=false;
static int gSettingsToken=0;
static dispatch_source_t gTimer=NULL;

static NSString *OwnershipPath(void) {
    return [[CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"CPUthermalBypassState.plist"];
}
static void SaveOwnership(BOOL owned) {
    NSString *path=OwnershipPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [@{@"ownsPause":@(owned)} writeToFile:path atomically:YES];
}
static BOOL LoadOwnership(void) {
    return [[[NSDictionary dictionaryWithContentsOfFile:OwnershipPath()] objectForKey:@"ownsPause"] boolValue];
}

static io_service_t CopyService(const char *name) {
    return IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching(name));
}
static NSDictionary *CopyProperties(io_service_t service) {
    if(service==IO_OBJECT_NULL)return nil;
    CFMutableDictionaryRef props=NULL;
    if(IORegistryEntryCreateCFProperties(service,&props,kCFAllocatorDefault,0)!=KERN_SUCCESS||!props)return nil;
    return CFBridgingRelease(props);
}
static io_service_t CopyBattery(void) {
    const char *names[]={"AppleSmartBattery","IOPMPowerSource","AppleARMPMUPowerSource"};
    for(size_t i=0;i<sizeof(names)/sizeof(names[0]);i++){io_service_t s=CopyService(names[i]);if(s!=IO_OBJECT_NULL)return s;}
    return IO_OBJECT_NULL;
}
static io_service_t CopyManager(void) {
    const char *names[]={"AppleSmartBatteryManager","AppleARMPMUCharger","ApplePMU"};
    for(size_t i=0;i<sizeof(names)/sizeof(names[0]);i++){io_service_t s=CopyService(names[i]);if(s!=IO_OBJECT_NULL)return s;}
    return IO_OBJECT_NULL;
}
static NSInteger Capacity(NSDictionary *props) {
    id raw=props[@"AppleRawBatteryPercent"]?:props[@"CurrentCapacity"];
    return [raw respondsToSelector:@selector(integerValue)]?[raw integerValue]:-1;
}
static BOOL AdapterConnected(NSDictionary *props) {
    NSDictionary *adapter=[props[@"AdapterDetails"] isKindOfClass:[NSDictionary class]]?props[@"AdapterDetails"]:nil;
    NSString *desc=[adapter[@"Description"] isKindOfClass:[NSString class]]?adapter[@"Description"]:nil;
    if(adapter.count&&![desc isEqualToString:@"batt"])return YES;
    return [props[@"ExternalChargeCapable"] boolValue]||[props[@"ExternalConnected"] boolValue];
}

// 写两个实际存在于 iOS 15-17 电池栈的边界；任一成功即视为适配成功。
// 不写 ChargingCurrentLimit：不同 PMU 对 0 的语义不一致，可能被解释为“解除限制”。
static BOOL SetPaused(BOOL paused) {
    BOOL success=NO;
    io_service_t manager=CopyManager();
    if(manager!=IO_OBJECT_NULL){
        NSDictionary *values=@{@"ChargeInhibit":@(paused),@"ChargeBlocked":@(paused)};
        success|=(IORegistryEntrySetCFProperties(manager,(__bridge CFTypeRef)values)==KERN_SUCCESS);
        IOObjectRelease(manager);
    }
    io_service_t battery=CopyBattery();
    if(battery!=IO_OBJECT_NULL){
        // 保留 ExternalConnected；只改变暂停位，形成适配器带整机、电池停止补电的旁路效果。
        NSDictionary *values=@{@"ChargeInhibit":@(paused),@"ChargingPaused":@(paused),@"PredictiveChargingInhibit":@NO};
        success|=(IORegistryEntrySetCFProperties(battery,(__bridge CFTypeRef)values)==KERN_SUCCESS);
        IOObjectRelease(battery);
    }
    if(success){
        atomic_store_explicit(&gPaused,paused,memory_order_release);
        SaveOwnership(paused);
    }
    return success;
}
static void Evaluate(void) {
    BOOL enabled=atomic_load_explicit(&gEnabled,memory_order_acquire);
    BOOL paused=atomic_load_explicit(&gPaused,memory_order_acquire);
    if(!enabled){if(paused)SetPaused(NO);return;}
    io_service_t battery=CopyBattery(); if(battery==IO_OBJECT_NULL)return;
    NSDictionary *props=CopyProperties(battery); IOObjectRelease(battery); if(!props)return;
    NSInteger capacity=Capacity(props),stop=atomic_load_explicit(&gStopLevel,memory_order_acquire);
    if(capacity<0)return;
    if(!paused&&capacity>=stop&&AdapterConnected(props))SetPaused(YES);
    else if(paused&&capacity<=MAX(5,stop-5))SetPaused(NO);
}
static void ReloadPrefs(void) {
    NSDictionary *prefs=CPUthermalReadPrefs()?:@{};
    BOOL enabled=[prefs[@"bypassChargeEnabled"] boolValue];
    NSInteger stop=[prefs[@"bypassChargeStopLevel"] respondsToSelector:@selector(integerValue)]?[prefs[@"bypassChargeStopLevel"] integerValue]:95;
    atomic_store_explicit(&gStopLevel,(int)MAX(70,MIN(100,stop)),memory_order_release);
    atomic_store_explicit(&gEnabled,enabled,memory_order_release);
    Evaluate();
}
static void StartTimer(void) {
    if(gTimer)return;
    gTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(gTimer,dispatch_walltime(NULL,0),5*NSEC_PER_SEC,250*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer,^{Evaluate();});
    dispatch_resume(gTimer);
}
%ctor { @autoreleasepool {
    atomic_store_explicit(&gPaused,LoadOwnership(),memory_order_release);
    ReloadPrefs(); StartTimer();
    dispatch_queue_t q=dispatch_queue_create("com.huayuarc.cputhermal.bypass.preferences",DISPATCH_QUEUE_SERIAL);
    notify_register_dispatch(kCPUthermalSettingsChangedNotifC,&gSettingsToken,q,^(int token){(void)token;ReloadPrefs();});
} }
