#import <UIKit/UIKit.h>
#import <notify.h>

static NSInteger kKeyboardTheme = 0;   // 0=default, 1=black, 2=gray, 3=custom
static BOOL kRoundCorners = NO;
static CGFloat kRadius = 10.1;
static UIColor *kCustomColor = nil;
static CGFloat kCustomAlpha = 0.8;

static UIColor *colorFromHex(NSString *hex) {
	if (!hex || hex.length < 6) return [UIColor blackColor];
	if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
	if (hex.length < 6) return [UIColor blackColor];

	unsigned int rgb = 0;
	[[NSScanner scannerWithString:hex] scanHexInt:&rgb];

	CGFloat r = ((rgb >> 16) & 0xFF) / 255.0;
	CGFloat g = ((rgb >> 8) & 0xFF) / 255.0;
	CGFloat b = (rgb & 0xFF) / 255.0;
	return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

static void loadPrefs(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.marsnakly.ios8darkkeyboard.plist"];
	if (!prefs) return;

	kKeyboardTheme = [prefs[@"keyboard_theme"] integerValue];
	kRoundCorners = [prefs[@"enable_round_corners"] boolValue];

	CGFloat val = [prefs[@"round_rect_radius"] floatValue];
	if (val > 0) kRadius = val;

	NSString *hex = prefs[@"custom_color_hex"];
	kCustomColor = hex ? colorFromHex(hex) : [UIColor blackColor];

	CGFloat alpha = [prefs[@"custom_color_alpha"] floatValue];
	kCustomAlpha = (alpha > 0) ? alpha : 0.8;
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	loadPrefs();
}

%ctor {
	loadPrefs();
	CFNotificationCenterAddObserver(
		CFNotificationCenterGetDarwinNotifyCenter(),
		NULL,
		prefsChangedCallback,
		CFSTR("com.marsnakly.ios8darkkeyboard.prefschanged"),
		NULL,
		CFNotificationSuspensionBehaviorCoalesce
	);
}

%hook UITextInputTraits
- (long long)keyboardAppearance {
	if (kKeyboardTheme == 1) return -2;   // 黑色
	if (kKeyboardTheme == 2) return 2;    // 灰色
	return %orig;                          // 默认 / 自定义颜色
}
%end

%hook UIKeyboardImpl
- (void)layoutSubviews {
	%orig;
	if (kKeyboardTheme == 3 && kCustomColor) {
		UIView *kbView = (UIView *)self;
		UIView *bg = [kbView viewWithTag:0xD0D0];
		if (!bg) {
			bg = [[UIView alloc] initWithFrame:kbView.bounds];
			bg.tag = 0xD0D0;
			bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
			bg.userInteractionEnabled = NO;
			[kbView insertSubview:bg atIndex:0];
		}
		bg.backgroundColor = kCustomColor;
		bg.alpha = kCustomAlpha;
		bg.frame = kbView.bounds;
	}
}
%end

%hook UIKBRenderGeometry
- (void)setRoundRectRadius:(double)arg1 {
	if (kRoundCorners) arg1 = kRadius;
	%orig;
}
%end
