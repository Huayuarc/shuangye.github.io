#import <UIKit/UIKit.h>
#import <notify.h>

static NSString *const kPrefPath = @"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist";
static NSString *const kPictureInPictureKey = @"pictureInPicture";
static NSString *const kScreenModeKey = @"screenMode";
static NSString *const kKeyboardRoundRectEnabledKey = @"keyboardRoundRectEnabled";
static NSString *const kKeyboardRoundRectRadiusKey = @"keyboardRoundRectRadius";
static NSString *const kNotifyPrefsChanged = @"com.huayuarc.systempro.prefschanged";

static BOOL g_pictureInPicture = NO;
static NSInteger g_screenMode = 0;
static BOOL g_keyboardRoundRectEnabled = NO;
static CGFloat g_keyboardRoundRectRadius = 16.1;

static BOOL boolPreference(NSDictionary *prefs, NSString *key, BOOL defaultValue) {
	id value = prefs[key];
	return value ? [value boolValue] : defaultValue;
}

static NSInteger integerPreference(NSDictionary *prefs, NSString *key, NSInteger defaultValue) {
	id value = prefs[key];
	return value ? [value integerValue] : defaultValue;
}

static CGFloat doublePreference(NSDictionary *prefs, NSString *key, CGFloat defaultValue) {
	id value = prefs[key];
	return value ? [value doubleValue] : defaultValue;
}

static CGFloat clampedKeyboardRoundRectRadius(CGFloat radius) {
	if (radius > 0.0 && radius <= 1.0) {
		radius *= 40.0;
	}
	if (radius < 0.0) return 0.0;
	if (radius > 40.0) return 40.0;
	return radius;
}

static void reloadConfiguration(void) {
	@autoreleasepool {
		NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
		g_pictureInPicture = boolPreference(prefs, kPictureInPictureKey, NO);
		g_screenMode = integerPreference(prefs, kScreenModeKey, 0);
		g_keyboardRoundRectEnabled = boolPreference(prefs, kKeyboardRoundRectEnabledKey, NO);
		g_keyboardRoundRectRadius = clampedKeyboardRoundRectRadius(doublePreference(prefs, kKeyboardRoundRectRadiusKey, 16.1));
	}
}

static BOOL isApplicationProcess(void) {
	NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
	return [bundlePath containsString:@"/Application"];
}

%group SystemproIPadAppStyle
%hook UITraitCollection
+ (id)traitCollectionWithHorizontalSizeClass:(NSInteger)horizontalSizeClass {
	if (UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation)) {
		return %orig(2);
	}
	return %orig;
}
%end
%end

%group SystemproKeyboardAdjust
%hook UIKBRenderGeometry
- (void)setRoundRectRadius:(double)radius {
	if (g_keyboardRoundRectEnabled) {
		radius = g_keyboardRoundRectRadius;
	}
	%orig(radius);
}
%end
%end

%group SystemproPictureInPicture
#define SystemproMGKey(key) (string && CFEqual(string, CFSTR(key)))
extern "C" Boolean MGGetBoolAnswer(CFStringRef string);
%hookf(Boolean, MGGetBoolAnswer, CFStringRef string) {
	if (SystemproMGKey("nVh/gwNpy7Jv1NOk00CMrw")) {
		return YES;
	}
	return %orig;
}
%end

static void onPrefsChanged(CFNotificationCenterRef center,
						   void *observer,
						   CFNotificationName name,
						   const void *object,
						   CFDictionaryRef userInfo) {
	reloadConfiguration();
}

%ctor {
	@autoreleasepool {
		reloadConfiguration();
		%init(SystemproKeyboardAdjust);

		if (g_pictureInPicture) {
			%init(SystemproPictureInPicture);
		}

		if (g_screenMode == 0 && isApplicationProcess()) {
			%init(SystemproIPadAppStyle);
		}

		CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
		if (!center) return;
		CFNotificationCenterAddObserver(center, NULL, onPrefsChanged,
			(__bridge CFStringRef)kNotifyPrefsChanged, NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately);
	}
}
