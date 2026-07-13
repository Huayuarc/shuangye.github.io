// Gravity Lite — 主屏幕图标物理引擎（重力/弹跳）
// 移植自 Cyanide: tweaks/gravitylite.m

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>

#pragma mark - Preferences

static NSString *const kGPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";
static NSString *const kGEnabledKey = @"cyanide_gravity";
static NSString *const kGStrengthKey = @"cyanide_gravityStrength";

static BOOL     g_gravityEnabled   = NO;
static CGFloat  g_gravityMagnitude = 0.5;

static void *kGravityAnimatorKey = &kGravityAnimatorKey;

#pragma mark - Preferences Reload

static void g_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	g_gravityEnabled   = [prefs[kGEnabledKey] boolValue];
	g_gravityMagnitude = [prefs[kGStrengthKey] floatValue];
	if (g_gravityMagnitude <= 0) g_gravityMagnitude = 0.5;
	if (g_gravityMagnitude > 5.0) g_gravityMagnitude = 5.0;
}

static void g_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	g_reloadPreferences();
}

#pragma mark - Gravity Helpers

static UIDynamicAnimator *g_getAnimator(id viewController) {
	UIDynamicAnimator *animator = objc_getAssociatedObject(viewController, kGravityAnimatorKey);
	if (!animator && [viewController isViewLoaded]) {
		animator = [[UIDynamicAnimator alloc] initWithReferenceView:[viewController view]];
		objc_setAssociatedObject(viewController, kGravityAnimatorKey, animator, OBJC_ASSOCIATION_RETAIN);
	}
	return animator;
}

static void g_applyGravity(id iconListVC) {
	UIView *view = [iconListVC view];
	if (!view) return;

	UIDynamicAnimator *animator = g_getAnimator(iconListVC);

	for (UIDynamicBehavior *b in animator.behaviors) {
		[animator removeBehavior:b];
	}
	if (!g_gravityEnabled) return;

	UIGravityBehavior *gravity = [[UIGravityBehavior alloc] init];
	gravity.magnitude = g_gravityMagnitude;
	[animator addBehavior:gravity];

	UICollisionBehavior *collision = [[UICollisionBehavior alloc] init];
	collision.translatesReferenceBoundsIntoBoundary = YES;
	[animator addBehavior:collision];

	UIDynamicItemBehavior *itemBehavior = [[UIDynamicItemBehavior alloc] init];
	itemBehavior.elasticity = 0.3;
	itemBehavior.friction = 0.5;
	itemBehavior.resistance = 0.5;
	[animator addBehavior:itemBehavior];

	for (UIView *subview in view.subviews) {
		if ([subview isKindOfClass:objc_getClass("SBIconView")]) {
			[gravity addItem:subview];
			[collision addItem:subview];
			[itemBehavior addItem:subview];
		}
	}
}

#pragma mark - Logos Hooks

%hook SBIconListViewController
- (void)viewDidAppear:(BOOL)animated {
	%orig;
	g_applyGravity(self);
}
- (void)viewDidLayoutSubviews {
	%orig;
	if (g_gravityEnabled) g_applyGravity(self);
}
%end

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		g_reloadPreferences();

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			g_prefsChangedCallback,
			(__bridge CFStringRef)kGPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
