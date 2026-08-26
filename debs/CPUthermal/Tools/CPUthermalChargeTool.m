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
static NSDictionary *OwnedState(void) {
    return [NSDictionary dictionaryWithContentsOfFile:StatePath()]?:@{};
}
static void SaveOwnership(BOOL ownsInhibit,BOOL ownsInputCutoff) {
    NSString *path=StatePath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [@{S("ownsInhibit"):@(ownsInhibit),S("ownsInputCutoff"):@(ownsInputCutoff)} writeToFile:path atomically:YES];
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

// 只在跨越阈值时写一次：先设置系统抑制位，再断开电池侧输入连接状态。
// 不写 IsCharging 或任何电流字段，避免轮询期间反复干扰适配器握手。
static BOOL ApplyStopState(void) {
    io_service_t service=BatteryService(); if(service==IO_OBJECT_NULL)return NO;
    NSDictionary *values=@{S("IsCharging"):@YES,S("PredictiveChargingInhibit"):@YES,S("ExternalConnected"):@NO};
    kern_return_t result=IORegistryEntrySetCFProperties(service,(__bridge CFTypeRef)values);
    IOObjectRelease(service);
    BOOL applied=(result==KERN_SUCCESS);
    SaveOwnership(applied,applied);
    return applied;
}
static BOOL ApplyResumeState(void) {
    NSDictionary *state=OwnedState();
    BOOL ownsInhibit=[state[S("ownsInhibit")] boolValue];
    BOOL ownsInputCutoff=[state[S("ownsInputCutoff")] boolValue];
    io_service_t service=BatteryService(); if(service==IO_OBJECT_NULL)return NO;
    NSDictionary *properties=BatteryProperties(service);
    BOOL cablePresent=AdapterConnected(properties);
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    if(ownsInhibit)values[S("PredictiveChargingInhibit")]=@NO;
    // IsCharging=YES 用于清除 powerd 缓存的“暂停/温度过高”原因；它不是电流控制，
    // 实际是否进电仍由电池管理器和 ExternalConnected 决定。
    values[S("IsCharging")]=@YES;
    if(ownsInputCutoff&&cablePresent)values[S("ExternalConnected")]=@YES;
    kern_return_t result=IORegistryEntrySetCFProperties(service,(__bridge CFTypeRef)values);
    IOObjectRelease(service);
    if(result==KERN_SUCCESS)SaveOwnership(NO,NO);
    return result==KERN_SUCCESS;
}

static void EvaluateBattery(BOOL preferenceEvent) {
    NSDictionary *prefs=CPUthermalReadPrefs()?:@{};
    BOOL enabled=[prefs[S("smartChargeEnabled")] boolValue];
    NSInteger stopLevel=MAX(70,MIN(100,IntegerValue(prefs,S("smartChargeStopLevel"),80)));
    NSDictionary *state=OwnedState();
    BOOL stopped=[state[S("ownsInhibit")] boolValue]||[state[S("ownsInputCutoff")] boolValue];

    // 开关关闭时仅在本插件持有停充状态时恢复一次；此后轮询保持只读。
    if(!enabled) {
        if(stopped)ApplyResumeState();
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
    if(capacity>=0) {
        if(capacity>=stopLevel&&connected&&!stopped)ApplyStopState();
        else if(capacity<=resumeLevel&&stopped)ApplyResumeState();
    }
    gLastEnabled=enabled; gLastStopLevel=stopLevel;
    (void)preferenceEvent;
}

// 升级/卸载清理：仅恢复本插件拥有的抑制和输入断流状态。
static BOOL ResetOwnedState(void) {
    NSDictionary *state=OwnedState();
    if(![state[S("ownsInhibit")] boolValue]&&![state[S("ownsInputCutoff")] boolValue])return YES;
    return ApplyResumeState();
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
