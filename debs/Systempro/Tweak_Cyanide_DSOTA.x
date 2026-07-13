// Disable OTA Updates — 禁用系统 OTA 更新
// 移植自 Cyanide: tweaks/darksword_ota.m
// 原理: 在 /var/db/com.apple.xpc.launchd/disabled.plist 中禁用 OTA 相关 daemon

#import <UIKit/UIKit.h>
#import <notify.h>
#import <spawn.h>

#pragma mark - Preferences

static NSString *const kOTAPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kOTAPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";
static NSString *const kOTAEnabledKey = @"cyanide_disableOTA";

static BOOL g_otaEnabled = NO;

static NSString *const kOTADisabledPlistPath = @"/var/db/com.apple.xpc.launchd/disabled.plist";

static NSArray<NSString *> *ota_daemonLabels(void) {
	return @[
		@"com.apple.mobile.softwareupdated",
		@"com.apple.OTATaskingAgent",
		@"com.apple.softwareupdateservicesd",
		@"com.apple.mobile.NRDUpdated",
	];
}

static NSArray<NSString *> *ota_customerCatalogPrefPaths(void) {
	return @[
		@"/var/mobile/Library/Preferences/com.apple.softwareupdateservicesd.plist",
		@"/var/mobile/Library/Preferences/com.apple.MobileSoftwareUpdate.plist",
	];
}

#pragma mark - OTA Disable Logic

static BOOL ota_applyDisabled(BOOL disabled) {
	// 读取 disabled.plist
	NSError *readError = nil;
	NSMutableDictionary *plist = nil;
	NSData *data = [NSData dataWithContentsOfFile:kOTADisabledPlistPath options:NSDataReadingMappedAlways error:&readError];

	if (data.length == 0) {
		plist = [NSMutableDictionary dictionary];
	} else {
		plist = [[NSPropertyListSerialization propertyListWithData:data
														  options:NSPropertyListMutableContainersAndLeaves
														   format:nil
															error:&readError] mutableCopy];
		if (![plist isKindOfClass:[NSMutableDictionary class]]) {
			plist = [NSMutableDictionary dictionary];
		}
	}

	BOOL changed = NO;
	for (NSString *label in ota_daemonLabels()) {
		if (disabled) {
			if (![plist[label] boolValue]) {
				plist[label] = @YES;
				changed = YES;
			}
		} else {
			if (plist[label]) {
				[plist removeObjectForKey:label];
				changed = YES;
			}
		}
	}

	if (!changed) return YES;

	// 写回 disabled.plist
	NSData *outData = [NSPropertyListSerialization dataWithPropertyList:plist
																 format:NSPropertyListXMLFormat_v1_0
																options:0
																  error:nil];
	if (outData.length == 0) return NO;

	BOOL written = [outData writeToFile:kOTADisabledPlistPath atomically:YES];
	if (!written) {
		// fallback: 尝试通过 spawn 用 chmod + cp
		pid_t pid;
		const char *args[] = {"bash", "-c", "chmod 644 /var/db/com.apple.xpc.launchd/disabled.plist 2>/dev/null; cat > /var/db/com.apple.xpc.launchd/disabled.plist", NULL};
		posix_spawn(&pid, "/bin/bash", NULL, NULL, (char *const *)args, NULL);
		written = [outData writeToFile:kOTADisabledPlistPath atomically:YES];
	}

	return written;
}

#pragma mark - Preferences Reload

static void ota_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	BOOL newVal = [prefs[kOTAEnabledKey] boolValue];
	if (newVal != g_otaEnabled) {
		g_otaEnabled = newVal;
		ota_applyDisabled(g_otaEnabled);
	}
}

static void ota_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	ota_reloadPreferences();
}

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		ota_reloadPreferences();

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			ota_prefsChangedCallback,
			(__bridge CFStringRef)kOTAPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
