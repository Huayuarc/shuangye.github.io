#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import <dlfcn.h>
#import <spawn.h>
#import <unistd.h>

static NSString *const kPrefPath          = @"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist";
static NSString *const kEnabledKey        = @"enabled";
static NSString *const kBlockModeKey      = @"blockMode";
static NSString *const kBlockModeGroupKey = @"blockModeGroup";
static NSString *const kKeyProperty       = @"key";

static const char *const kNotifyPrefsChanged = "com.huayuarc.systempro.prefschanged";
static const char *const kNotifyRespring     = "com.huayuarc.systempro.respring";


static const char *LSExecutablePath(const char *jbrootRelativePath, const char *rootlessPath, const char *rootfulPath) {
	char *(*jbrootFunction)(const char *) = (char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
	const char *resolvedPath = jbrootFunction ? jbrootFunction(jbrootRelativePath) : NULL;
	if (resolvedPath && access(resolvedPath, X_OK) == 0) return resolvedPath;
	if (rootlessPath && access(rootlessPath, X_OK) == 0) return rootlessPath;
	if (rootfulPath && access(rootfulPath, X_OK) == 0) return rootfulPath;
	return NULL;
}

static BOOL LSLaunchExecutable(const char *executablePath, char *const arguments[]) {
	if (!executablePath) return NO;
	pid_t processID = 0;
	return posix_spawn(&processID, executablePath, NULL, NULL, arguments, NULL) == 0;
}

static BOOL LSPerformRespring(void) {
	char *const sbreloadArguments[] = {(char *)"sbreload", NULL};
	const char *sbreloadPath = LSExecutablePath("/usr/bin/sbreload", "/var/jb/usr/bin/sbreload", "/usr/bin/sbreload");
	if (LSLaunchExecutable(sbreloadPath, sbreloadArguments)) return YES;

	char *const killallArguments[] = {(char *)"killall", (char *)"-9", (char *)"SpringBoard", NULL};
	const char *killallPath = LSExecutablePath("/usr/bin/killall", "/var/jb/usr/bin/killall", "/usr/bin/killall");
	return LSLaunchExecutable(killallPath, killallArguments);
}

typedef NS_ENUM(NSInteger, LSBlockMode) {
	LSBlockModeLowPower = 0,
	LSBlockModeSilent   = 1,
	LSBlockModeAlways   = 2,
};

static NSInteger sanitizedBlockMode(id value) {
	NSInteger mode = [value integerValue];
	if (mode != LSBlockModeLowPower &&
		mode != LSBlockModeSilent &&
		mode != LSBlockModeAlways) {
		return LSBlockModeAlways;
	}
	return mode;
}

@interface LLRootListController : PSListController
@end

@interface LLNotificationListController : LLRootListController
@end

@interface LLDisableListController : LLRootListController
@end

@interface LLSystemListController : LLRootListController
@end

@implementation LLRootListController

- (NSString *)specifiersPlistName {
	return @"Root";
}

- (instancetype)init {
	self = [super init];
	if (self) {
		UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"注销"
			style:UIBarButtonItemStylePlain target:self action:@selector(respring)];
		self.navigationItem.rightBarButtonItem = btn;
	}
	return self;
}

- (NSArray *)specifiers {
	if (!_specifiers) {
		NSArray *loadedSpecs = [self loadSpecifiersFromPlistName:[self specifiersPlistName] target:self];
		NSMutableArray *specs = loadedSpecs ? [loadedSpecs mutableCopy] : [NSMutableArray array];

		NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
		BOOL enabled = [d[kEnabledKey] boolValue];
		if (!enabled) {
			NSSet *hideKeys = [NSSet setWithObjects:kBlockModeGroupKey, kBlockModeKey, nil];
			NSMutableArray *filtered = [NSMutableArray array];
			for (PSSpecifier *spec in specs) {
				NSString *key = [spec propertyForKey:kKeyProperty];
				if (![hideKeys containsObject:key]) {
					[filtered addObject:spec];
				}
			}
			specs = filtered;
		}

		_specifiers = [specs copy];
	}
	return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
	NSString *key = [spec propertyForKey:kKeyProperty];
	if (!key) return nil;

	NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
	id val = d ? d[key] : nil;

	if (!val) {
		val = [spec propertyForKey:@"default"];
	}

	if ([key isEqualToString:kBlockModeKey]) {
		return @(sanitizedBlockMode(val));
	}

	return val ?: nil;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
	NSString *key = [spec propertyForKey:kKeyProperty];
	if (!key) return;

	NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefPath];
	if (!d) d = [NSMutableDictionary dictionary];

	if ([key isEqualToString:kBlockModeKey]) {
		value = @(sanitizedBlockMode(value));
	}
	if (value) {
		d[key] = value;
	} else {
		[d removeObjectForKey:key];
	}
	[d writeToFile:kPrefPath atomically:YES];

	if ([key isEqualToString:kEnabledKey]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_specifiers = nil;
			[self reloadSpecifiers];
		});
	}

	notify_post(kNotifyPrefsChanged);
}

- (id)getPref:(PSSpecifier *)spec {
	return [self readPreferenceValue:spec];
}

- (void)setPref:(id)val spec:(PSSpecifier *)spec {
	[self setPreferenceValue:val specifier:spec];
}

- (void)respring {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"注销"
		message:@"确定要注销吗？"
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		notify_post(kNotifyRespring);
		LSPerformRespring();
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end

@implementation LLNotificationListController

- (NSString *)specifiersPlistName {
	return @"Notification";
}

@end

@implementation LLDisableListController

- (NSString *)specifiersPlistName {
	return @"Disable";
}

@end

@implementation LLSystemListController

- (NSString *)specifiersPlistName {
	return @"System";
}

@end
