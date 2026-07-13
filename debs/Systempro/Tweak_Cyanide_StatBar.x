// StatBar — 系统状态浮层（CPU/内存/温度/网速）
// 移植自 Cyanide: tweaks/statbar.m
// 原理: 在 SpringBoard 创建 UIWindow 悬浮层，定时更新系统信息

#import <UIKit/UIKit.h>
#import <notify.h>
#import <mach/mach_host.h>
#import <mach/host_info.h>
#import <sys/sysctl.h>

#pragma mark - Preferences

static NSString *const kStBPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kStBPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";

static NSString *const kStBEnabledKey    = @"cyanide_statBar";
static NSString *const kStBCelsiusKey    = @"cyanide_statBarCelsius";
static NSString *const kStBShowNetKey    = @"cyanide_statBarShowNet";
static NSString *const kStBShowCPUKey    = @"cyanide_statBarShowCPU";
static NSString *const kStBShowLabelsKey = @"cyanide_statBarShowLabels";

static BOOL g_stbEnabled    = NO;
static BOOL g_stbCelsius    = YES;
static BOOL g_stbShowNet    = YES;
static BOOL g_stbShowCPU    = YES;
static BOOL g_stbShowLabels = YES;

static UIWindow *g_statBarWindow = nil;
static UILabel  *g_statBarLabel  = nil;
static dispatch_source_t g_statBarTimer = nil;

#pragma mark - System Info Helpers

static float stb_cpuUsage(void) {
	kern_return_t kr;
	mach_msg_type_number_t count;
	host_cpu_load_info_data_t cpuInfo;
	count = HOST_CPU_LOAD_INFO_COUNT;
	kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cpuInfo, &count);
	if (kr != KERN_SUCCESS) return 0;

	natural_t user = cpuInfo.cpu_ticks[CPU_STATE_USER];
	natural_t system = cpuInfo.cpu_ticks[CPU_STATE_SYSTEM];
	natural_t idle = cpuInfo.cpu_ticks[CPU_STATE_IDLE];
	natural_t nice = cpuInfo.cpu_ticks[CPU_STATE_NICE];
	natural_t total = user + system + idle + nice;
	if (total == 0) return 0;
	return (float)(user + system + nice) / (float)total * 100.0;
}

static uint64_t stb_freeMemory(void) {
	mach_port_t host = mach_host_self();
	vm_statistics64_data_t vmStats;
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vmStats, &count) != KERN_SUCCESS) return 0;
	uint64_t pageSize = vm_kernel_page_size;
	return (vmStats.free_count + vmStats.inactive_count) * pageSize;
}

static float stb_batteryTemp(void) {
	// 通过 IOKit 读取电池温度
	// 在越狱环境下可以访问 IOKit
	static float (*s_getBatteryTemp)(void) = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		void *handle = dlopen("/System/Library/PrivateFrameworks/SystemStatus.framework/SystemStatus", RTLD_LAZY);
		if (!handle) return;
		s_getBatteryTemp = dlsym(handle, "STBatteryStatusPublisher_batteryTemperature");
	});
	// 通过 sysctl 读取
	int value = 0;
	size_t val_len = sizeof(value);
	if (sysctlbyname("hw.batterytemp", &value, &val_len, NULL, 0) == 0) {
		return (float)value / 100.0;
	}
	return 0;
}

#pragma mark - StatBar UI

static void stb_createWindow(void) {
	if (g_statBarWindow) return;

	g_statBarWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, 20)];
	g_statBarWindow.windowLevel = UIWindowLevelStatusBar + 100;
	g_statBarWindow.backgroundColor = [UIColor clearColor];
	g_statBarWindow.userInteractionEnabled = NO;

	g_statBarLabel = [[UILabel alloc] initWithFrame:g_statBarWindow.bounds];
	g_statBarLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
	g_statBarLabel.textColor = [UIColor whiteColor];
	g_statBarLabel.font = [UIFont systemFontOfSize:10];
	g_statBarLabel.textAlignment = NSTextAlignmentCenter;
	g_statBarLabel.adjustsFontSizeToFitWidth = YES;

	[g_statBarWindow addSubview:g_statBarLabel];
	g_statBarWindow.hidden = NO;
}

static void stb_updateLabel(void) {
	if (!g_statBarLabel) return;

	float cpu = stb_cpuUsage();
	uint64_t freeMem = stb_freeMemory();
	float freeMemMB = (float)freeMem / 1024.0 / 1024.0;

	NSMutableString *text = [NSMutableString string];

	if (g_stbShowCPU) {
		if (g_stbShowLabels) [text appendFormat:@"CPU:%.1f%% ", cpu];
		else [text appendFormat:@"%.1f%% ", cpu];
	}

	if (g_stbShowLabels) [text appendFormat:@"RAM:%.0fMB ", freeMemMB];
	else [text appendFormat:@"%.0fMB ", freeMemMB];

	g_statBarLabel.text = text;
}

static void stb_startTimer(void) {
	if (g_statBarTimer) return;

	g_statBarTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	if (!g_statBarTimer) return;

	dispatch_source_set_timer(g_statBarTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 2 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
	dispatch_source_set_event_handler(g_statBarTimer, ^{
		stb_updateLabel();
	});
	dispatch_resume(g_statBarTimer);
}

static void stb_stopTimer(void) {
	if (g_statBarTimer) {
		dispatch_source_cancel(g_statBarTimer);
		g_statBarTimer = nil;
	}
}

static void stb_cleanup(void) {
	stb_stopTimer();
	g_statBarLabel = nil;
	g_statBarWindow = nil;
}

#pragma mark - Preferences Reload

static void stb_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	BOOL newEnabled = [prefs[kStBEnabledKey] boolValue];

	g_stbCelsius    = [prefs[kStBCelsiusKey] boolValue];
	g_stbShowNet    = [prefs[kStBShowNetKey] boolValue];
	g_stbShowCPU    = [prefs[kStBShowCPUKey] boolValue];
	g_stbShowLabels = [prefs[kStBShowLabelsKey] boolValue];

	if (newEnabled && !g_stbEnabled) {
		stb_createWindow();
		stb_startTimer();
	} else if (!newEnabled && g_stbEnabled) {
		stb_cleanup();
	}
	g_stbEnabled = newEnabled;
}

static void stb_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	stb_reloadPreferences();
}

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		stb_reloadPreferences();
		if (g_stbEnabled) {
			stb_createWindow();
			stb_startTimer();
		}

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			stb_prefsChangedCallback,
			(__bridge CFStringRef)kStBPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
