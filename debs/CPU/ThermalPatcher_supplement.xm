#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#include <IOKit/IOKitLib.h>
#include <CPUthermalPaths.h>

// 日志总开关，打包正式版可改为 0 关闭所有NSLog
#define CPUTHERMAL_LOG_ENABLE 1
#if CPUTHERMAL_LOG_ENABLE
#define CT_LOG(fmt, ...) NSLog(@"[CPUthermal-supplement] " fmt, ##__VA_ARGS__)
#else
#define CT_LOG(fmt, ...)
#endif

// ============================================================================
// 前置函数声明（消除隐式调用编译警告，与Tweak.xm统一接口）
// ============================================================================
NSInteger CPUthermalNativeMaxPCoreFrequencyMHz(void);
int lowPowerTargetValue(void);
NSDictionary* CPUthermalReadPrefs(void);

// ============================================================================
// 本地配置缓存（与 Tweak.xm 独立，通过 CFNotification 同步）
// 增加互斥锁，多守护进程并发读写防止脏数据崩溃
// ============================================================================
static dispatch_semaphore_t s_prefLock;
static BOOL s_enabled = YES;
static BOOL s_cpuProtection = YES;
static BOOL s_brightnessProtection = YES;

typedef enum {
S_PowerModeFull = 0,
S_PowerModeLow  = 1
} S_PowerMode;
static S_PowerMode s_powerMode = S_PowerModeFull;

// 温度安全阀（与 Tweak.xm 保持一致，单位：千分之一摄氏度 70000=70℃）
static const int64_t s_safetyTempThreshold = 70000;
static int64_t s_cachedTemp = 0;
static CFAbsoluteTime s_cachedTempTime = 0;

static void s_loadPrefs(void) {
dispatch_semaphore_wait(s_prefLock, DISPATCH_TIME_FOREVER);
@autoreleasepool {
NSDictionary *d = CPUthermalReadPrefs();
if (!d) {
dispatch_semaphore_signal(s_prefLock);
return;
}
s_enabled = [d[S("enabled")] ?: @YES boolValue];
s_cpuProtection = [d[S("cpuProtection")] ?: @YES boolValue];
s_brightnessProtection = [d[S("brightnessProtection")] ?: @YES boolValue];
NSString *mode = d[S("powerMode")] ?: S("fullPower");
s_powerMode = [mode isEqualToString:S("lowPower")] ? S_PowerModeLow : S_PowerModeFull;
}
dispatch_semaphore_signal(s_prefLock);
}

static BOOL s_isFullPower(void) {
dispatch_semaphore_wait(s_prefLock, DISPATCH_TIME_FOREVER);
BOOL ret = s_enabled && s_cpuProtection && s_powerMode == S_PowerModeFull;
dispatch_semaphore_signal(s_prefLock);
return ret;
}

static BOOL s_isLowPower(void) {
dispatch_semaphore_wait(s_prefLock, DISPATCH_TIME_FOREVER);
BOOL ret = s_enabled && s_cpuProtection && s_powerMode == S_PowerModeLow;
dispatch_semaphore_signal(s_prefLock);
return ret;
}

// 简化版温度检查（轻量，1.5s缓存，避免频繁读取IORegistry占用CPU）
static BOOL s_isAboveSafetyCeiling(void) {
CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
// 缓存未过期，直接返回缓存温度判断
if (s_cachedTempTime > 0 && (now - s_cachedTempTime) < 1.5) {
return s_cachedTemp >= s_safetyTempThreshold;
}

int64_t temp = 0;
CFMutableDictionaryRef matching = IOServiceMatching("AppleARMPlatform");
if (matching) {
io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
if (service != MACH_PORT_NULL) {
CFStringRef tempKey = CFStringCreateWithCString(kCFAllocatorDefault, "temperature", kCFStringEncodingUTF8);
CFTypeRef tempVal = IORegistryEntryCreateCFProperty(service, tempKey, kCFAllocatorDefault, 0);

if (tempVal && CFGetTypeID(tempVal) == CFNumberGetTypeID()) {
CFNumberGetValue((CFNumberRef)tempVal, kCFNumberSInt64Type, &temp);
}
// 修复：所有CF对象强制释放，无内存泄漏
if (tempKey) CFRelease(tempKey);
if (tempVal) CFRelease(tempVal);
IOObjectRelease(service);
}
}

if (temp > 0) {
s_cachedTemp = temp;
s_cachedTempTime = now;
return temp >= s_safetyTempThreshold;
}
// 读取温度失败：保守策略，放行系统原生温控，防止高温事故
return YES;
}

// ============================================================================
// 类前置声明（避免编译找不到类定义）
// ============================================================================
@interface ThermalMonitor : NSObject
- (int)thermalLevel;
- (NSDictionary *)thermalMitigationData;
@end

@interface DVFSController : NSObject
+ (void)configureWithPolicy:(NSDictionary *)policy;
- (double)maxSupportedFrequency;
- (BOOL)applyThermalThrottling;
@end

@interface SBBrightnessController : NSObject
- (void)setBrightnessLevel:(float)level forReason:(NSString *)reason;
@end

@interface Launchd : NSObject
- (BOOL)shouldKeepRunningService:(NSString *)serviceName;
@end

@interface CSDevice : NSObject
- (BOOL)_isThermalStateRestricted;
- (BOOL)_shouldReducePerformance;
@end

// ============================================================================
// ThermalMonitor — 系统热监控管理器拦截
// 作用：替换系统温控策略，输出自定义满频/低频参数
// ============================================================================
%hook ThermalMonitor

- (int)thermalLevel {
if (s_isFullPower() && !s_isAboveSafetyCeiling()) {
// thermalLevel=0 代表无热限制
return 0;
}
return %orig;
}

- (NSDictionary *)thermalMitigationData {
// 总开关关闭 / CPU保护关闭 / 温度超标，完全交还系统原生温控
if (!s_enabled || !s_cpuProtection || s_isAboveSafetyCeiling()) {
return %orig;
}

if (s_isFullPower()) {
NSInteger maxPCoreMHz = CPUthermalNativeMaxPCoreFrequencyMHz();
CT_LOG(@"输出满频温控策略，大核上限：%ld MHz", (long)maxPCoreMHz);
return @{
S("CPUMaxFreq"):   @(maxPCoreMHz * 1000000LL),
S("GPUMaxFreq"):   @(3240000000.0),
S("CPUPriority"):  @(255),
S("IOPriority"):   @(255),
S("VoltageScale"): @(1.0),
S("ThermalClamp"): @(0)
};
}

if (s_isLowPower()) {
NSInteger lowFreqMHz = lowPowerTargetValue();
CT_LOG(@"输出重度手游省电策略，限制频率：%ld MHz | 调度优先级220", (long)lowFreqMHz);
return @{
S("CPUMaxFreq"):   @(lowFreqMHz * 1000000LL),
S("GPUMaxFreq"):   @(lowFreqMHz * 1000000LL),
S("CPUPriority"):  @(220),
S("IOPriority"):   @(220),
S("VoltageScale"): @(0.8),
S("ThermalClamp"): @(1)
};
}
return %orig;
}

%end

// ============================================================================
// DVFSController — CPU动态电压调频拦截
// 阻止系统主动降频、覆盖最大支持频率
// ============================================================================
%hook DVFSController

- (double)maxSupportedFrequency {
BOOL overTemp = s_isAboveSafetyCeiling();
if (s_isFullPower() && !overTemp) {
double fullFreq = (double)CPUthermalNativeMaxPCoreFrequencyMHz() * 1000000.0;
return fullFreq;
}
if (s_isLowPower() && !overTemp) {
double lowFreq = (double)lowPowerTargetValue() * 1000000.0;
return lowFreq;
}
return %orig;
}

- (BOOL)applyThermalThrottling {
// 未超温+满血模式，返回NO阻止系统热降频
if (s_isFullPower() && !s_isAboveSafetyCeiling()) {
return NO;
}
return %orig;
}

%end

// ============================================================================
// Launchd — 系统进程管理
// 阻止温控类守护进程持续运行，减少后台强制限频行为
// ============================================================================
%hook Launchd

- (BOOL)shouldKeepRunningService:(NSString *)serviceName {
// 功能关闭 / 省电模式 / 超温，不拦截系统服务
if (!s_enabled || !s_cpuProtection || !s_isFullPower() || !serviceName) {
return %orig;
}
if (s_isAboveSafetyCeiling()) {
return %orig;
}

NSString *svcLower = [serviceName lowercaseString];
static NSArray *thermalBlacklist = nil;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
thermalBlacklist = @[
S("com.apple.thermalmonitord"),
S("com.apple.mobilethermalservice"),
S("com.apple.perfpowerservicesextended"),
S("com.apple.fpsmonitor")
];
});

// 精准完整匹配进程名，避免误杀powermanagement基础电源服务
for (NSString *svc in thermalBlacklist) {
if ([svcLower isEqualToString:svc]) {
CT_LOG(@"屏蔽温控后台进程：%@", serviceName);
return NO;
}
}
return %orig;
}

%end

// ============================================================================
// CSDevice — CoreServices设备性能限制接口
// 关闭系统性能受限标记，上层App读取不到热限制状态
// ============================================================================
%hook CSDevice

- (BOOL)_isThermalStateRestricted {
if (s_isFullPower() && !s_isAboveSafetyCeiling()) {
return NO;
}
return %orig;
}

- (BOOL)_shouldReducePerformance {
if (s_isFullPower() && !s_isAboveSafetyCeiling()) {
return NO;
}
return %orig;
}

%end

// ============================================================================
// 配置变更通知回调（C函数，供CFNotificationCenterAddObserver使用）
// ============================================================================
static void s_prefsChangedCallback(CFNotificationCenterRef center, void *observer,
CFStringRef name, const void *object, CFDictionaryRef userInfo) {
s_loadPrefs();
CT_LOG(@"检测到配置变更，重载偏好缓存");
}

// ============================================================================
// Tweak入口构造函数：初始化锁、加载配置、注册偏好监听
// ============================================================================
%ctor {
@autoreleasepool {
// 初始化偏好读写互斥锁
s_prefLock = dispatch_semaphore_create(1);
s_loadPrefs();

// 注册偏好变更通知，修改设置自动重载缓存
CFNotificationCenterRef notifyCenter = CFNotificationCenterGetDarwinNotifyCenter();
if (notifyCenter) {
CFNotificationCenterAddObserver(
notifyCenter,
NULL,
s_prefsChangedCallback,
(__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),
NULL,
CFNotificationSuspensionBehaviorDeliverImmediately
);
}
CT_LOG(@"模块加载完成 | 总开关:%d CPU保护:%d 亮度保护:%d 模式:%s",
s_enabled,
s_cpuProtection,
s_brightnessProtection,
s_isFullPower() ? "满血满频" : (s_isLowPower() ? "重度手游省电2400MHz" : "关闭")
);
}
}