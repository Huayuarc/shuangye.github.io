#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "EvanescoPrefs.h"
static NSTimer *timer;static NSMapTable *saved;static BOOL applied,enabled,hideDock,hideStatus,hideDockSearch;
static BOOL touching,onHome=YES,editing,backgroundChanged,statusChanged,pageChanged;
static CGFloat alpha;static NSTimeInterval delay;
static id Msg(id o,NSString*s){SEL q=NSSelectorFromString(s);return o&&[o respondsToSelector:q]?((id(*)(id,SEL))objc_msgSend)(o,q):nil;}
static void BoolMsg(id o,NSString*s,BOOL v){SEL q=NSSelectorFromString(s);if(o&&[o respondsToSelector:q])((void(*)(id,SEL,BOOL))objc_msgSend)(o,q,v);}
static void Load(){enabled=[EVRead(@"enabled",@YES)boolValue];hideDock=[EVRead(@"hideDock",@YES)boolValue];hideStatus=[EVRead(@"hideStatusBar",@YES)boolValue];hideDockSearch=[EVRead(@"hideDockSearch",@YES)boolValue];alpha=[EVRead(@"alpha",EVRead(@"fadeAmount",@0.0))doubleValue];delay=MAX(1,[EVRead(@"timeDelay",@6)doubleValue]);}
static id IconController(){Class c=NSClassFromString(@"SBIconController");return Msg(c,@"sharedInstance");}
static id RootController(){id i=IconController();for(NSString*s in @[@"_rootFolderController",@"rootFolderController"]) {id r=Msg(i,s);if(r)return r;}return nil;}
static NSArray* Windows(){NSMutableOrderedSet*a=[NSMutableOrderedSet orderedSet];for(UIScene*s in UIApplication.sharedApplication.connectedScenes)if([s isKindOfClass:UIWindowScene.class])[a addObjectsFromArray:((UIWindowScene*)s).windows];@try{[a addObjectsFromArray:[UIApplication.sharedApplication valueForKey:@"windows"]];}@catch(id e){}return a.array;}
static BOOL Has(id x,NSString*n){return x&&[NSStringFromClass([x class])rangeOfString:n options:NSCaseInsensitiveSearch].location!=NSNotFound;}
static void SaveAlpha(UIView*v){if(v&&![saved objectForKey:v])[saved setObject:@(v.alpha) forKey:v];}
static void SetAlpha(UIView*v,CGFloat a){if(!v)return;SaveAlpha(v);v.alpha=a;}
static void WalkLists(UIView*v,CGFloat a){if(!v)return;NSString*n=NSStringFromClass(v.class);if([n containsString:@"IconListView"]||[n containsString:@"WidgetView"]||[n containsString:@"PageControl"]){SetAlpha(v,a);return;}for(UIView*x in v.subviews)WalkLists(x,a);}
static id Content(){return Msg(RootController(),@"contentView");}
static id CurrentList(){id r=RootController();for(NSString*s in @[@"currentIconListView",@"iconListView",@"currentListView"]){id v=Msg(r,s);if(v)return v;}return nil;}
static id DockList(){id r=RootController();for(NSString*s in @[@"dockListView",@"dockView"]){id v=Msg(r,s);if(v)return v;}return nil;}
static id DockView(){id c=Content();return Msg(c,@"dockView")?:DockList();}
static id FloatingWindow(){for(UIWindow*w in Windows())if(Has(w,@"SBFloatingDockWindow"))return w;return nil;}
static void Background(id d,CGFloat a){SEL s=NSSelectorFromString(@"setBackgroundAlpha:");if(d&&[d respondsToSelector:s])((void(*)(id,SEL,double))objc_msgSend)(d,s,a);}
static void Status(BOOL h){id w=nil;@try{w=[UIApplication.sharedApplication valueForKey:@"statusBarWindow"];}@catch(id e){}if(w)BoolMsg(w,@"setHidden:",h);for(UIWindow*x in Windows())if(Has(x,@"StatusBar"))x.hidden=h;}
static void Page(BOOL h){id r=RootController();BoolMsg(r,@"setPageControlHidden:",h);id c=Content();BoolMsg(c,@"setPageControlHidden:",h);}
static void Restore(){if(!applied&&!saved.count)return;[UIView performWithoutAnimation:^{for(UIView*v in saved){NSNumber*n=[saved objectForKey:v];if(v&&n)v.alpha=n.doubleValue;}[saved removeAllObjects];if(backgroundChanged)Background(DockView(),1);if(pageChanged)Page(NO);if(statusChanged)Status(NO);}];backgroundChanged=statusChanged=pageChanged=NO;applied=NO;}
static void Apply(){Load();if(!enabled||touching||!onHome||editing)return;Restore();id cur=CurrentList(),dock=DockList(),content=Content();[UIView performWithoutAnimation:^{SetAlpha(cur,alpha);WalkLists(content,alpha);if(hideDock){SetAlpha(dock,alpha);Background(DockView(),alpha);backgroundChanged=YES;id r=Msg(FloatingWindow(),@"floatingDockRootViewController");id v=Msg(r,@"view");if([v isKindOfClass:UIView.class])SetAlpha(v,alpha);}if(hideDockSearch)for(UIView*v in [DockView() subviews])if(Has(v,@"DSSearchBar")||Has(v,@"MPAScrollView")||Has(v,@"MTMaterialView")||Has(v,@"UILabel"))SetAlpha(v,alpha);Page(YES);pageChanged=YES;if(hideStatus){Status(YES);statusChanged=YES;}}];applied=YES;}
static void Schedule(){if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(),^{Schedule();});return;}Load();[timer invalidate];timer=nil;Restore();if(enabled&&onHome&&!editing&&!touching)timer=[NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(__unused NSTimer*t){Apply();}];}
static void Changed(__unused CFNotificationCenterRef c,__unused void*o,__unused CFStringRef n,__unused const void*x,__unused CFDictionaryRef i){Schedule();}
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)a {
    %orig;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,Changed,EVNotify,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    Schedule();
}
- (void)frontDisplayDidChange:(id)a {
    %orig;
    onHome=!(a&&[a isKindOfClass:NSClassFromString(@"SBApplication")]);
    touching=NO;
    Schedule();
}
%end
%hook SBHomeScreenWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    if(applied&&e&&e.type==UIEventTypeTouches) Schedule();
    return %orig;
}
- (void)sendEvent:(UIEvent *)e {
    if(e.allTouches.count||e.type==UIEventTypePresses){
        touching=NO;
        for(UITouch*t in e.allTouches) if(t.phase!=UITouchPhaseEnded&&t.phase!=UITouchPhaseCancelled) touching=YES;
        Schedule();
    }
    %orig;
}
%end
%hook SBFloatingDockWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    if(applied&&e&&e.type==UIEventTypeTouches) Schedule();
    return %orig;
}
- (void)sendEvent:(UIEvent *)e {
    if(e.allTouches.count){
        touching=NO;
        for(UITouch*t in e.allTouches) if(t.phase!=UITouchPhaseEnded&&t.phase!=UITouchPhaseCancelled) touching=YES;
        Schedule();
    }
    %orig;
}
%end
%hook SBUIController
- (void)handleHomeButtonSinglePressUp {
    Schedule();
    %orig;
}
- (void)handleHomeButtonDoublePressDown {
    Schedule();
    %orig;
}
%end
%hook CSCoverSheetViewController
- (void)finishUIUnlockFromSource:(NSInteger)s {
    %orig;
    onHome=YES;touching=NO;Schedule();
}
- (void)setInScreenOffMode:(BOOL)o forAutoUnlock:(BOOL)a fromUnlockSource:(NSInteger)s {
    %orig;
    if(o){onHome=NO;touching=NO;Schedule();}
}
%end
%hook SBFolderController
- (void)setEditing:(BOOL)e animated:(BOOL)a {
    editing=e;Schedule();
    %orig;
}
%end
%ctor {
    @autoreleasepool { saved=[NSMapTable weakToStrongObjectsMapTable]; }
}
