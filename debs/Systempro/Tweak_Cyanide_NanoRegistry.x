// NanoRegistry — Apple Watch 配对兼容版本覆盖
// 移植自 Cyanide: tweaks/nano_registry.m
// 原理: 修改 /var/mobile/Library/Preferences/com.apple.NanoRegistry.plist 中的配对版本限制

#import <UIKit/UIKit.h>
#import <notify.h>

#pragma mark - Preferences

static NSString *const kNRPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kNRPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";
static NSString *const kNREnabledKey = @"cyanide_nanoRegistry";
static NSString *const kNRMaxPairingKey = @"cyanide_nanoMaxPairing";
static NSString *const kNRMinPairingKey = @"cyanide_nanoMinPairing";

static BOOL g_nrEnabled = NO;
static int g_nrMaxPairing = 99;
static int g_nrMinPairing = 23;

static NSString *const kNRPlistPath = @"/var/mobile/Library/Preferences/com.apple.NanoRegistry.plist";

static NSString *const kKeyMax = @"maxPairingCompatibilityVersion";
static NSString *const kKeyMin = @"minPairingCompatibilityVersion";
static NSString *const kKeyMinChipID = @"minPairingCompatibilityVersionWithChipID";
static NSString *const kKeyMinQuick = @"minQuickSwitchCompatibilityVersion";

#pragma mark - NanoRegistry Logic

static BOOL nr_applyOverrides(BOOL apply) {
	NSError *error = nil;
	NSMutableDictionary *plist = nil;

	NSData *data = [NSData dataWithContentsOfFile:kNRPlistPath options:NSDataReadingMappedAlways error:&error];
	if (data.length > 0) {
		plist = [[NSPropertyListSerialization propertyListWithData:data
														  options:NSPropertyListMutableContainersAndLeaves
														   format:nil
															error:&error] mutableCopy];
	}
	if (![plist isKindOfClass:[NSMutableDictionary class]]) {
		plist = [NSMutableDictionary dictionary];
	}

	if (apply) {
		plist[kKeyMax] = @(g_nrMaxPairing);
		plist[kKeyMin] = @(g_nrMinPairing);
		plist[kKeyMinChipID] = @(g_nrMinPairing);
		plist[kKeyMinQuick] = @(g_nrMaxPairing);
	} else {
		[plist removeObjectForKey:kKeyMax];
		[plist removeObjectForKey:kKeyMin];
		[plist removeObjectForKey:kKeyMinChipID];
		[plist removeObjectForKey:kKeyMinQuick];
	}

	NSData *outData = [NSPropertyListSerialization dataWithPropertyList:plist
																 format:NSPropertyListXMLFormat_v1_0
																options:0
																  error:nil];
	if (outData.length == 0) return NO;

	BOOL written = [outData writeToFile:kNRPlistPath atomically:YES];

	// 触发 nanoregistryd 重新读取
	notify_post("com.apple.nanoregistry.pairingcompatibilityversion");

	return written;
}

#pragma mark - Preferences Reload

static void nr_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	BOOL newEnabled = [prefs[kNREnabledKey] boolValue];
	int newMax = (int)[prefs[kNRMaxPairingKey] integerValue];
	int newMin = (int)[prefs[kNRMinPairingKey] integerValue];

	if (newMax <= 0) newMax = 99;
	if (newMin <= 0) newMin = 23;

	BOOL changed = (newEnabled != g_nrEnabled) || (newMax != g_nrMaxPairing) || (newMin != g_nrMinPairing);
	if (!changed) return;

	g_nrEnabled = newEnabled;
	g_nrMaxPairing = newMax;
	g_nrMinPairing = newMin;

	nr_applyOverrides(g_nrEnabled);
}

static void nr_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	nr_reloadPreferences();
}

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		nr_reloadPreferences();

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			nr_prefsChangedCallback,
			(__bridge CFStringRef)kNRPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
