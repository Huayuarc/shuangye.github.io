#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import <CPUthermalPaths.h>

static int gNotifyToken = 0;
static BOOL gLastEnabled = NO;
static NSInteger gLastStopLevel = -1;

static NSString *StatePath(void) {
    return [[CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:S("CPUthermalChargeState.plist")];
}
static BOOL OwnsChargingInhibit(void) {
    return [[NSDictionary dictionaryWithContentsOfFile:StatePath()][S("ownsInhibit")] boolValue];
}
static void SaveOwnership(BOOL owns) {
    NSString *path=StatePath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [@{S("ownsInhibit"):@(owns)} writeToFile:path atomically:YES];
}
static io_service_t BatteryService(void) {
    io_service_t service=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("AppleSmartBattery"));
    if(service==IO_OBJECT_NULL)service=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("IOPMPowerSource"));
    return service;
}
static NSDictionary *BatteryProperties(io_service_t service) {
    if(service==IO_OBJECT_NULL)return nil;
    CFMutableDictionaryRef properties=NULL;
    if(IORegistryEntryCreateCFProperties(service,&properties,kCFAllocatorDefault,0)!=KERN_SUCCESS||!properties)return nil;
    return CFBridgingRelease(properties);
}
static BOOL AdapterConnected(NSDictionary *properties) {
    NSDictionary *adapter=[properties[S("AdapterDetails")] isKindOfClass:[NSDictionary class]]?properties[S("AdapterDetails")]:nil;
    NSString *description=[adapter[S("Description")] isKindOfClass:[NSString class]]?adapter[S("Description")]:nil;
    if(adapter.count&&![description isEqualToString:S("batt")])return YES;
    return [properties[S("ExternalChargeCapable")] boolValue]||[properties[S("ExternalConnected")] boolValue];
}
static NSInteger IntegerValue(NSDictionary *dictionary,NSString *key,NSInteger fallback) {
    id value=dictionary[key]; return [value respondsToSelector:@selector(integerValue)]?[value integerValue]:fallback;
}

// 唯一写入的电池属性。插件只撤销自己设置的 inhibit，不接管 IsCharging、
// ExternalConnected、充电电流、输入电流或适配器协商状态。
static BOOL SetOwnedInhibit(BOOL inhibit) {
    io_service_t service=BatteryService(); if(service==IO_OBJECT_NULL)return NO;
    kern_return_t result=IORegistryEntrySetCFProperty(service,CFSTR("PredictiveChargingInhibit"),inhibit?kCFBooleanTrue:kCFBooleanFalse);
    IOObjectRelease(service);
    if(result==KERN_SUCCESS)SaveOwnership(inhibit);
    return result==KERN_SUCCESS;
}

static void EvaluateBattery(BOOL preferenceEvent) {
    NSDictionary *prefs=CPUthermalReadPrefs()?:@{};
    BOOL enabled=[prefs[S("smartChargeEnabled")] boolValue];
    NSInteger stopLevel=MAX(70,MIN(100,IntegerValue(prefs,S("smartChargeStopLevel"),80)));
    BOOL owns=OwnsChargingInhibit();

    // 开关关闭时，只有从开启切到关闭或本插件确实持有 inhibit 才单次恢复；
    // 此后定时检查保持只读，不再扰动充电握手。
    if(!enabled) {
        if(owns)SetOwnedInhibit(NO);
        gLastEnabled=NO; gLastStopLevel=stopLevel;
        return;
    }

    io_service_t service=BatteryService();
    NSDictionary *properties=BatteryProperties(service);
    if(service!=IO_OBJECT_NULL)IOObjectRelease(service);
    if(!properties)return;

    NSInteger capacity=IntegerValue(properties,S("CurrentCapacity"),-1);
    NSInteger resumeLevel=MAX(5,stopLevel-5);
    BOOL connected=AdapterConnected(properties);
    if(capacity>=0&&connected) {
        if(capacity>=stopLevel&&!owns)SetOwnedInhibit(YES);
        else if(capacity<=resumeLevel&&owns)SetOwnedInhibit(NO);
    }
    gLastEnabled=enabled; gLastStopLevel=stopLevel;
    (void)preferenceEvent;
}

// 升级/卸载清理：只清除 PredictiveChargingInhibit 和本插件所有权标记。
// 不写 ExternalConnected/IsCharging，让 powerd 与充电 IC 自行重新协商。
static BOOL ResetOwnedState(void) {
    io_service_t service=BatteryService();
    if(service==IO_OBJECT_NULL){SaveOwnership(NO);return NO;}
    kern_return_t result=IORegistryEntrySetCFProperty(service,CFSTR("PredictiveChargingInhibit"),kCFBooleanFalse);
    IOObjectRelease(service); SaveOwnership(NO); return result==KERN_SUCCESS;
}
static void SignalHandler(int signalNumber) { (void)signalNumber; _exit(0); }

int main(int argc,char **argv) { @autoreleasepool {
    if(argc>1&&strcmp(argv[1],"reset")==0)return ResetOwnedState()?0:2;
    signal(SIGTERM,SignalHandler); signal(SIGINT,SignalHandler); signal(SIGHUP,SignalHandler);
    NSDictionary *initial=CPUthermalReadPrefs()?:@{};
    gLastEnabled=[initial[S("smartChargeEnabled")] boolValue];
    gLastStopLevel=MAX(70,MIN(100,IntegerValue(initial,S("smartChargeStopLevel"),80)));
    notify_register_dispatch(kCPUthermalSettingsChangedNotifC,&gNotifyToken,dispatch_get_main_queue(),^(int token){(void)token;EvaluateBattery(YES);});
    // 只读轮询电量；仅跨越停充/恢复阈值时产生一次属性写入。
    [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(__unused NSTimer *timer){EvaluateBattery(NO);}];
    EvaluateBattery(NO);
    [[NSRunLoop mainRunLoop] run];
} return 0; }
