// Call Recording Sound Mute — 谨言通话录音提示音
// 移植自 Cyanide: tweaks/call_recording_sound.m
// 原理: 替换系统的 StartDisclosureWithTone.m4a / StopDisclosure.caf 为无声文件

#import <UIKit/UIKit.h>
#import <notify.h>
#import <spawn.h>

#pragma mark - Preferences

static NSString *const kCRSPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kCRSPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";
static NSString *const kCRSEnabledKey = @"cyanide_muteCallRecord";

static BOOL g_crsEnabled = NO;

static NSString *const kCRSTargetDir = @"/var/mobile/Library/CallServices/Greetings/default";
static NSString *const kCRSBackupDir = @"/var/mobile/Library/Preferences/com.huayuarc.systempro.callrecord.backup";

static const char *kCRSFileNames[] = {
	"StartDisclosureWithTone.m4a",
	"StopDisclosure.caf",
};

// 生成一个 1 秒的静默音频文件（WAV 头 + 静音数据）
static NSData *crs_silentAudioData(void) {
	// 44 字节 WAV 头 + 8000 字节静音 PCM (1秒, 8kHz, 8-bit mono)
	const int sampleRate = 8000;
	const int duration = 1;
	const int dataSize = sampleRate * duration;
	const int fileSize = 44 + dataSize;

	uint8_t *buf = malloc(fileSize);
	if (!buf) return nil;

	// WAV header
	memcpy(buf, "RIFF", 4);
	uint32_t riffSize = fileSize - 8;
	memcpy(buf + 4, &riffSize, 4);
	memcpy(buf + 8, "WAVE", 4);
	memcpy(buf + 12, "fmt ", 4);
	uint32_t fmtSize = 16;
	memcpy(buf + 16, &fmtSize, 4);
	uint16_t audioFmt = 1; // PCM
	memcpy(buf + 20, &audioFmt, 2);
	uint16_t channels = 1;
	memcpy(buf + 22, &channels, 2);
	memcpy(buf + 24, &sampleRate, 4);
	uint32_t byteRate = sampleRate;
	memcpy(buf + 28, &byteRate, 4);
	uint16_t blockAlign = 1;
	memcpy(buf + 32, &blockAlign, 2);
	uint16_t bitsPerSample = 8;
	memcpy(buf + 34, &bitsPerSample, 2);
	memcpy(buf + 36, "data", 4);
	memcpy(buf + 40, &dataSize, 4);

	// 静音数据（全零 = 静音）
	memset(buf + 44, 0, dataSize);

	NSData *data = [NSData dataWithBytesNoCopy:buf length:fileSize freeWhenDone:YES];
	return data;
}

static BOOL crs_ensureDirectories(void) {
	NSFileManager *fm = [NSFileManager defaultManager];

	NSError *error = nil;
	if (![fm fileExistsAtPath:kCRSBackupDir]) {
		[fm createDirectoryAtPath:kCRSBackupDir withIntermediateDirectories:YES attributes:nil error:&error];
	}
	if (![fm fileExistsAtPath:kCRSTargetDir]) {
		[fm createDirectoryAtPath:kCRSTargetDir withIntermediateDirectories:YES attributes:nil error:&error];
		// 尝试 chmod 使目录可写
		pid_t pid;
		const char *args[] = {"bash", "-c", "chmod 755 /var/mobile/Library/CallServices/Greetings 2>/dev/null; chmod 755 /var/mobile/Library/CallServices/Greetings/default 2>/dev/null", NULL};
		posix_spawn(&pid, "/bin/bash", NULL, NULL, (char *const *)args, NULL);
	}
	return YES;
}

static BOOL crs_backupOriginal(const char *fileName) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *srcPath = [NSString stringWithFormat:@"%s/%s", kCRSTargetDir.UTF8String, fileName];
	NSString *dstPath = [NSString stringWithFormat:@"%@/%s.orig", kCRSBackupDir, fileName];

	if ([fm fileExistsAtPath:dstPath]) return YES;
	if (![fm fileExistsAtPath:srcPath]) return YES;

	NSError *error = nil;
	return [fm copyItemAtPath:srcPath toPath:dstPath error:&error];
}

static BOOL crs_applyMute(BOOL mute) {
	crs_ensureDirectories();

	NSData *silentData = crs_silentAudioData();
	if (!silentData) return NO;

	size_t count = sizeof(kCRSFileNames) / sizeof(kCRSFileNames[0]);
	BOOL allOK = YES;

	for (size_t i = 0; i < count; i++) {
		NSString *filePath = [NSString stringWithFormat:@"%s/%s", kCRSTargetDir.UTF8String, kCRSFileNames[i]];

		if (mute) {
			// 备份原文件
			crs_backupOriginal(kCRSFileNames[i]);
			// 写入静音文件
			NSError *error = nil;
			BOOL written = [silentData writeToFile:filePath options:NSDataWritingAtomic error:&error];
			if (!written) {
				// fallback 通过 bash
				pid_t pid;
				NSString *script = [NSString stringWithFormat:@"cat > '%@'", filePath];
				const char *args[] = {"bash", "-c", [script UTF8String], NULL};
				posix_spawn(&pid, "/bin/bash", NULL, NULL, (char *const *)args, NULL);
			}
		} else {
			// 从备份恢复
			NSString *backupPath = [NSString stringWithFormat:@"%@/%s.orig", kCRSBackupDir, kCRSFileNames[i]];
			NSFileManager *fm = [NSFileManager defaultManager];
			if ([fm fileExistsAtPath:backupPath]) {
				NSError *error = nil;
				[fm removeItemAtPath:filePath error:nil];
				[fm copyItemAtPath:backupPath toPath:filePath error:&error];
			}
		}
	}

	return allOK;
}

#pragma mark - Preferences Reload

static void crs_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	BOOL newVal = [prefs[kCRSEnabledKey] boolValue];
	if (newVal != g_crsEnabled) {
		g_crsEnabled = newVal;
		crs_applyMute(g_crsEnabled);
	}
}

static void crs_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	crs_reloadPreferences();
}

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		crs_reloadPreferences();

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			crs_prefsChangedCallback,
			(__bridge CFStringRef)kCRSPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
