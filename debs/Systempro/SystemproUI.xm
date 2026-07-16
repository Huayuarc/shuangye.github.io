#import <UIKit/UIKit.h>
#import <notify.h>

@interface TUISystemInputAssistantView : UIView
@end

@interface TUIInputAssistantBackdropView : UIView
@end

static NSString *const kPrefPath = @"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist";
static NSString *const kPictureInPictureKey = @"pictureInPicture";
static NSString *const kScreenModeKey = @"screenMode";
static NSString *const kNotifyPrefsChanged = @"com.huayuarc.systempro.prefschanged";

static BOOL g_pictureInPicture = NO;
static NSInteger g_screenMode = 0;

static UIKeyboardAppearance SystemproKeyboardAppearance(void) {
	return UIKeyboardAppearanceDark;
}

static void SystemproCollapseKeyboardAssistantView(UIView *view) {
	view.hidden = YES;
	view.alpha = 0.0;
	view.userInteractionEnabled = NO;

	CGRect frame = view.frame;
	if (frame.size.height != 0.0) {
		frame.size.height = 0.0;
		view.frame = frame;
	}
}

static BOOL SystemproIsKeyboardHostedView(UIView *view) {
	UIWindow *window = view.window;
	NSString *windowClassName = window ? NSStringFromClass([window class]) : nil;
	if ([windowClassName containsString:@"Keyboard"] || [windowClassName containsString:@"TextEffects"]) {
		return YES;
	}

	UIView *ancestorView = view.superview;
	while (ancestorView) {
		NSString *ancestorClassName = NSStringFromClass([ancestorView class]);
		if ([ancestorClassName containsString:@"InputSet"] ||
			[ancestorClassName containsString:@"InputAssistant"] ||
			[ancestorClassName containsString:@"Keyboard"]) {
			return YES;
		}
		ancestorView = ancestorView.superview;
	}

	return NO;
}

static BOOL SystemproShouldCollapseToolbar(UIToolbar *toolbar) {
	return SystemproIsKeyboardHostedView(toolbar) && toolbar.items.count == 0;
}

static BOOL boolPreference(NSDictionary *prefs, NSString *key, BOOL defaultValue) {
	id value = prefs[key];
	return value ? [value boolValue] : defaultValue;
}

static NSInteger integerPreference(NSDictionary *prefs, NSString *key, NSInteger defaultValue) {
	id value = prefs[key];
	return value ? [value integerValue] : defaultValue;
}

static void reloadConfiguration(void) {
	@autoreleasepool {
		NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
		g_pictureInPicture = boolPreference(prefs, kPictureInPictureKey, NO);
		g_screenMode = integerPreference(prefs, kScreenModeKey, 0);
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

%group SystemproDarkKeyboard
%hook UITextInputTraits
- (UIKeyboardAppearance)keyboardAppearance {
	return SystemproKeyboardAppearance();
}

- (void)setKeyboardAppearance:(UIKeyboardAppearance)appearance {
	%orig(SystemproKeyboardAppearance());
}
%end

%hook UITextField
- (UIKeyboardAppearance)keyboardAppearance {
	return SystemproKeyboardAppearance();
}

- (void)setKeyboardAppearance:(UIKeyboardAppearance)appearance {
	%orig(SystemproKeyboardAppearance());
}
%end

%hook UITextView
- (UIKeyboardAppearance)keyboardAppearance {
	return SystemproKeyboardAppearance();
}

- (void)setKeyboardAppearance:(UIKeyboardAppearance)appearance {
	%orig(SystemproKeyboardAppearance());
}
%end

%hook TUISystemInputAssistantView
- (void)didMoveToWindow {
	%orig;
	SystemproCollapseKeyboardAssistantView(self);
}

- (void)layoutSubviews {
	%orig;
	SystemproCollapseKeyboardAssistantView(self);
}

- (CGSize)intrinsicContentSize {
	return CGSizeZero;
}

- (CGSize)sizeThatFits:(CGSize)size {
	return CGSizeZero;
}

- (void)setFrame:(CGRect)frame {
	frame.size.height = 0.0;
	%orig(frame);
}

- (void)setBounds:(CGRect)bounds {
	bounds.size.height = 0.0;
	%orig(bounds);
}
%end

%hook TUIInputAssistantBackdropView
- (void)didMoveToWindow {
	%orig;
	SystemproCollapseKeyboardAssistantView(self);
}

- (void)layoutSubviews {
	%orig;
	SystemproCollapseKeyboardAssistantView(self);
}

- (void)setFrame:(CGRect)frame {
	frame.size.height = 0.0;
	%orig(frame);
}
%end

%hook UIToolbar
- (void)layoutSubviews {
	%orig;
	if (SystemproShouldCollapseToolbar(self)) {
		SystemproCollapseKeyboardAssistantView(self);
	}
}

- (void)setFrame:(CGRect)frame {
	if (SystemproShouldCollapseToolbar(self)) {
		frame.size.height = 0.0;
	}
	%orig(frame);
}
%end
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

		if (g_pictureInPicture) {
			%init(SystemproPictureInPicture);
		}

		if (g_screenMode == 0 && isApplicationProcess()) {
			%init(SystemproIPadAppStyle);
		}

		%init(SystemproDarkKeyboard);

		CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
		if (!center) return;
		CFNotificationCenterAddObserver(center, NULL, onPrefsChanged,
			(__bridge CFStringRef)kNotifyPrefsChanged, NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately);
	}
}
