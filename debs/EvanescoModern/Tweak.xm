#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "EvanescoPrefs.h"

static NSTimer *evTimer;
static NSMapTable<UIView *, NSNumber *> *evSaved;
static NSHashTable<UIView *> *evHiddenStatusViews;
static BOOL evApplied, evEnabled, evHideDock, evHideStatus;
static CGFloat evAlpha; static NSTimeInterval evDelay;

static void EVLoad(void) {
    evEnabled=[EVValue(@"enabled",@YES) boolValue]; evHideDock=[EVValue(@"hideDock",@NO) boolValue];
    evHideStatus=[EVValue(@"hideStatusBar",@NO) boolValue];
    evAlpha=MAX(0.02,MIN(1,[EVValue(@"alpha",@0.05) doubleValue]));
    evDelay=MAX(1,[EVValue(@"timeDelay",@10) doubleValue]);
}
static NSString *EVClassName(id o) { return o ? NSStringFromClass([o class]) : @""; }
static BOOL EVHas(id o,NSString *s) { return [EVClassName(o) rangeOfString:s options:NSCaseInsensitiveSearch].location!=NSNotFound; }
static BOOL EVInDock(UIView *v) { for (UIView *p=v;p;p=p.superview) if (EVHas(p,@"Dock")) return YES; return NO; }
static BOOL EVLeafTarget(UIView *v) {
    NSString *n=EVClassName(v);
    return [n containsString:@"IconView"] || [n containsString:@"WidgetView"] || [n containsString:@"WidgetWrapper"] || [n containsString:@"PageControl"] || [n containsString:@"SearchPill"];
}
static void EVFade(UIView *v) { if (!v || [evSaved objectForKey:v]) return; [evSaved setObject:@(v.alpha) forKey:v]; v.alpha=evAlpha; }
static void EVWalk(UIView *v) {
    if (EVLeafTarget(v) && (!EVInDock(v)||evHideDock)) { EVFade(v); return; }
    for (UIView *s in v.subviews) EVWalk(s);
}
static NSArray<UIWindow *> *EVWindows(void) {
    NSMutableOrderedSet *set=[NSMutableOrderedSet orderedSet];
    UIApplication *app=UIApplication.sharedApplication;
    for (UIScene *s in app.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) [set addObjectsFromArray:((UIWindowScene *)s).windows];
    for (NSString *key in @[@"_windows",@"windows"]) @try { id value=[app valueForKey:key]; if ([value isKindOfClass:NSArray.class]) [set addObjectsFromArray:value]; } @catch (__unused NSException *e) {}
    return set.array;
}
static void EVSetStatusHidden(BOOL hidden) {
    Class c=objc_getClass("SBStatusBarManager"); id manager=nil;
    for (NSString *selName in @[@"sharedInstance",@"sharedManager"]) { SEL s=NSSelectorFromString(selName); if (c&&[c respondsToSelector:s]) { manager=((id(*)(id,SEL))objc_msgSend)(c,s); break; } }
    if (manager) for (NSString *selName in @[@"setStatusBarHidden:",@"setHidden:"]) { SEL s=NSSelectorFromString(selName); if ([manager respondsToSelector:s]) { ((void(*)(id,SEL,BOOL))objc_msgSend)(manager,s,hidden); break; } }
    for (UIWindow *w in EVWindows()) {
        if (EVHas(w,@"StatusBar")) { w.hidden=hidden; if (hidden) [evHiddenStatusViews addObject:w]; }
        NSMutableArray *stack=[NSMutableArray arrayWithObject:w];
        while (stack.count) { UIView *v=stack.lastObject; [stack removeLastObject]; if (EVHas(v,@"StatusBar") && !EVHas(v,@"HomeScreen")) { v.hidden=hidden; if(hidden)[evHiddenStatusViews addObject:v]; } [stack addObjectsFromArray:v.subviews]; }
    }
}
static void EVRestore(void) {
    for (UIView *v in evSaved) { NSNumber *a=[evSaved objectForKey:v]; if(v&&a)v.alpha=a.doubleValue; }
    [evSaved removeAllObjects];
    for (UIView *v in evHiddenStatusViews) if(v)v.hidden=NO; [evHiddenStatusViews removeAllObjects];
    if(evApplied&&evHideStatus)EVSetStatusHidden(NO); evApplied=NO;
}
static void EVApply(void) {
    EVLoad(); if(!evEnabled||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    EVRestore(); for(UIWindow *w in EVWindows()) if(EVHas(w,@"HomeScreen")||EVHas(w,@"SpringBoard")||w.windowLevel==UIWindowLevelNormal) EVWalk(w);
    if(evHideStatus)EVSetStatusHidden(YES); evApplied=YES;
}
static void EVSchedule(void) { dispatch_async(dispatch_get_main_queue(),^{ EVLoad(); [evTimer invalidate]; evTimer=nil; EVRestore(); if(evEnabled)evTimer=[NSTimer scheduledTimerWithTimeInterval:evDelay repeats:NO block:^(__unused NSTimer *t){EVApply();}]; }); }
static void EVSettingsChanged(__unused CFNotificationCenterRef c,__unused void *o,__unused CFStringRef n,__unused const void *x,__unused CFDictionaryRef i){EVSchedule();}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)arg { %orig; CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,EVSettingsChanged,EVNotify,NULL,CFNotificationSuspensionBehaviorDeliverImmediately); EVSchedule(); }
- (void)frontDisplayDidChange:(id)arg { %orig; if(arg)dispatch_async(dispatch_get_main_queue(),^{[evTimer invalidate];evTimer=nil;EVRestore();}); else EVSchedule(); }
%end
%hook SBHomeScreenWindow
- (void)sendEvent:(UIEvent *)event { if(event.allTouches.count||event.type==UIEventTypePresses)EVSchedule(); %orig; }
%end
%hook CSCoverSheetViewController
- (void)finishUIUnlockFromSource:(NSInteger)source { %orig; EVSchedule(); }
- (void)setInScreenOffMode:(BOOL)off forAutoUnlock:(BOOL)a fromUnlockSource:(NSInteger)s { %orig; if(off){[evTimer invalidate];evTimer=nil;EVRestore();} }
%end
%hook SBUIController
- (void)handleHomeButtonSinglePressUp { EVSchedule(); %orig; }
- (void)handleHomeButtonDoublePressDown { EVSchedule(); %orig; }
%end
%ctor { @autoreleasepool { evSaved=[NSMapTable weakToStrongObjectsMapTable]; evHiddenStatusViews=[NSHashTable weakObjectsHashTable]; } }
