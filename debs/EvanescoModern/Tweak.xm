#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "EvanescoPrefs.h"

static NSTimer *evTimer;
static NSMapTable<UIView *, NSNumber *> *evSaved;
static BOOL evApplied;
static BOOL evEnabled; static BOOL evHideDock; static BOOL evHideStatus; static CGFloat evAlpha; static NSTimeInterval evDelay;

static void EVLoad(void) {
    evEnabled = [EVValue(@"enabled", @YES) boolValue];
    evHideDock = [EVValue(@"hideDock", @NO) boolValue];
    evHideStatus = [EVValue(@"hideStatusBar", @NO) boolValue];
    evAlpha = MAX(0, MIN(1, [EVValue(@"alpha", @0) doubleValue]));
    evDelay = MAX(1, [EVValue(@"timeDelay", @10) doubleValue]);
}
static BOOL EVNameHas(UIView *v, NSString *needle) { return [NSStringFromClass(v.class) rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound; }
static BOOL EVIsDockView(UIView *v) {
    for (UIView *p=v; p; p=p.superview) if (EVNameHas(p,@"Dock") || EVNameHas(p,@"FloatingDock")) return YES;
    return NO;
}
static BOOL EVIsIconTarget(UIView *v) {
    NSString *n=NSStringFromClass(v.class);
    return ([n containsString:@"IconView"] || [n containsString:@"IconListView"] || [n containsString:@"IconGrid"] || [n containsString:@"RootFolderView"]);
}
static void EVStoreAndAlpha(UIView *v, CGFloat a) {
    if (!v || [evSaved objectForKey:v]) return;
    [evSaved setObject:@(v.alpha) forKey:v]; v.alpha=a;
}
static void EVWalk(UIView *v) {
    if (EVIsIconTarget(v) && (!EVIsDockView(v) || evHideDock)) EVStoreAndAlpha(v,evAlpha);
    if (evHideDock && (EVNameHas(v,@"DockView") || EVNameHas(v,@"FloatingDock"))) EVStoreAndAlpha(v,evAlpha);
    for (UIView *s in v.subviews) EVWalk(s);
}
static NSArray<UIWindow *> *EVWindows(void) {
    NSMutableArray *out=[NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) [out addObjectsFromArray:((UIWindowScene *)s).windows];
    return out;
}
static void EVRestore(void) {
    if (!evApplied) return;
    for (UIView *v in evSaved) { NSNumber *a=[evSaved objectForKey:v]; if (v && a) v.alpha=a.doubleValue; }
    [evSaved removeAllObjects]; evApplied=NO;
    if (evHideStatus) for (UIWindow *w in EVWindows()) if (EVNameHas(w,@"StatusBar")) w.hidden=NO;
}
static void EVApply(void) {
    EVLoad(); if (!evEnabled || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    EVRestore(); for (UIWindow *w in EVWindows()) EVWalk(w);
    if (evHideStatus) for (UIWindow *w in EVWindows()) if (EVNameHas(w,@"StatusBar")) w.hidden=YES;
    evApplied=YES;
}
static void EVSchedule(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ EVLoad(); [evTimer invalidate]; evTimer=nil; EVRestore(); if (evEnabled) evTimer=[NSTimer scheduledTimerWithTimeInterval:evDelay repeats:NO block:^(__unused NSTimer *t){ EVApply(); }]; });
}
static void EVSettingsChanged(__unused CFNotificationCenterRef c, __unused void *o, __unused CFStringRef n, __unused const void *x, __unused CFDictionaryRef i) { EVSchedule(); }

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)arg { %orig; if (!evSaved) evSaved=[NSMapTable weakToStrongObjectsMapTable]; CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, EVSettingsChanged, EVNotify, NULL, CFNotificationSuspensionBehaviorDeliverImmediately); EVSchedule(); }
%end
%hook UIApplication
- (void)sendEvent:(UIEvent *)event { %orig; if (event.allTouches.count || event.type==UIEventTypePresses) EVSchedule(); }
%end
%hook CSCoverSheetViewController
- (void)finishUIUnlockFromSource:(NSInteger)source { %orig; EVSchedule(); }
%end
%hook SBIconController
- (void)noteUserInteraction { %orig; EVSchedule(); }
%end

%ctor { @autoreleasepool { if (!evSaved) evSaved=[NSMapTable weakToStrongObjectsMapTable]; } }
