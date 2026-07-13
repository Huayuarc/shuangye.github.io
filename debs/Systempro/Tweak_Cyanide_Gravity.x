// Tweak_Cyanide_Gravity.x
// Ported from Cyanide gravitylite - Icon physics with gravity/bounce effects

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static BOOL g_cld_gravityEnabled = NO;
static CGFloat g_cld_gravityMagnitude = 0.5;
static CGFloat g_cld_gravityElasticity = 0.4;
static CGFloat g_cld_gravityFriction = 0.8;
static CGFloat g_cld_gravityResistance = 0.3;
static CGFloat g_cld_gravityAngularResistance = 0.5;

@interface SBIconListViewController : UIViewController
- (void)cld_applyGravity;
@end

%group GravityHooks

%hook SBIconListViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (g_cld_gravityEnabled) {
        [self cld_applyGravity];
    }
}

- (void)cld_applyGravity {
    // Apply UIDynamicAnimator to the icon list view
    UIDynamicAnimator *animator = [[UIDynamicAnimator alloc] initWithReferenceView:self.view];
    
    // Find all icon views
    NSMutableArray *iconViews = [NSMutableArray array];
    for (UIView *subview in self.view.subviews) {
        if ([subview isKindOfClass:objc_getClass("SBIconView")]) {
            [iconViews addObject:subview];
        }
    }
    
    if (iconViews.count == 0) return;
    
    // Gravity behavior
    UIGravityBehavior *gravity = [[UIGravityBehavior alloc] initWithItems:iconViews];
    gravity.magnitude = g_cld_gravityMagnitude;
    [animator addBehavior:gravity];
    
    // Collision behavior
    UICollisionBehavior *collision = [[UICollisionBehavior alloc] initWithItems:iconViews];
    collision.translatesReferenceBoundsIntoBoundary = YES;
    collision.collisionMode = UICollisionBehaviorModeEverything;
    [animator addBehavior:collision];
    
    // Item behavior
    UIDynamicItemBehavior *itemBehavior = [[UIDynamicItemBehavior alloc] initWithItems:iconViews];
    itemBehavior.elasticity = g_cld_gravityElasticity;
    itemBehavior.friction = g_cld_gravityFriction;
    itemBehavior.resistance = g_cld_gravityResistance;
    itemBehavior.angularResistance = g_cld_gravityAngularResistance;
    itemBehavior.allowsRotation = YES;
    [animator addBehavior:itemBehavior];
    
    // Store animator as associated object so it stays alive
    objc_setAssociatedObject(self, @selector(cld_applyGravity), animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%end // GravityHooks

static void cld_loadGravityPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_gravityEnabled = [prefs[@"cld_gravityEnabled"] boolValue];
    g_cld_gravityMagnitude = [prefs[@"cld_gravityMagnitude"] floatValue];
    if (g_cld_gravityMagnitude <= 0) g_cld_gravityMagnitude = 0.5;
    g_cld_gravityElasticity = [prefs[@"cld_gravityElasticity"] floatValue];
    g_cld_gravityFriction = [prefs[@"cld_gravityFriction"] floatValue];
    g_cld_gravityResistance = [prefs[@"cld_gravityResistance"] floatValue];
    g_cld_gravityAngularResistance = [prefs[@"cld_gravityAngularResistance"] floatValue];
    if (g_cld_gravityEnabled) {
        %init(GravityHooks);
    }
}

static void cld_Gravity_init(void) {
    cld_loadGravityPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadGravityPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

__attribute__((constructor)) static void cld_gravity_ctor(void) {
    cld_Gravity_init();
}
