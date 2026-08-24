#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "EvanescoPrefs.h"
static NSTimer *timer;static NSMapTable *saved;static BOOL applied,enabled,hideDock,hideStatus,hideDockSearch,preventDock;
static CGFloat alpha;static NSTimeInterval delay;
static id Msg(id o,NSString*s){SEL q=NSSelectorFromString(s);return o&&[o respondsToSelector:q]?((id(*)(id,SEL))objc_msgSend)(o,q):nil;}
static void BoolMsg(id o,NSString*s,BOOL v){SEL q=NSSelectorFromString(s);if(o&&[o respondsToSelector:q])((void(*)(id,SEL,BOOL))objc_msgSend)(o,q,v);}
static void Load(){CFPreferencesAppSynchronize((__bridge CFStringRef)EVDomain);enabled=[EVRead(@"enabled",@YES)boolValue];hideDock=[EVRead(@"hideDock",@YES)boolValue];hideStatus=[EVRead(@"hideStatusBar",@YES)boolValue];hideDockSearch=[EVRead(@"hideDockSearch",@YES)boolValue];alpha=[EVRead(@"alpha",EVRead(@"fadeAmount",@0.0))doubleValue];delay=MAX(1,[EVRead(@"timeDelay",@6)doubleValue]);}
static id IconController(){Class c=NSClassFromString(@"SBIconController");return Msg(c,@"sharedInstance");}
static id RootController(){id i=IconController();for(NSString*s in @[@"_rootFolderController",@"rootFolderController"]) {id r=Msg(i,s);if(r)return r;}return nil;}
static NSArray* Windows(){NSMutableOrderedSet*a=[NSMutableOrderedSet orderedSet];for(UIScene*s in UIApplication.sharedApplication.connectedScenes)if([s isKindOfClass:UIWindowScene.class])[a addObjectsFromArray:((UIWindowScene*)s).windows];@try{[a addObjectsFromArray:[UIApplication.sharedApplication valueForKey:@"windows"]];}@catch(id e){}return a.array;}
static BOOL Has(id x,NSString*n){return x&&[NSStringFromClass([x class])rangeOfString:n options:NSCaseInsensitiveSearch].location!=NSNotFound;}
static void SaveAlpha(UIView*v){if(v&&![saved objectForKey:v])[saved setObject:@(v.alpha) forKey:v];}
static void SetAlpha(UIView*v,CGFloat a){if(!v)return;SaveAlpha(v);v.alpha=a;}
// UIKit 对 alpha <= 0.01 的 View 停止 Hit-Testing。IconList 是分页手势容器，
// 视觉上保持近乎透明但必须高于阈值，才能让第一下滑动进入手势识别链。
static void SetInteractiveAlpha(UIView*v,CGFloat a){SetAlpha(v,MAX(a,0.011));}
static void WalkLists(UIView*v,CGFloat a){if(!v)return;NSString*n=NSStringFromClass(v.class);if([n containsString:@"IconListView"]){SetInteractiveAlpha(v,a);return;}if([n containsString:@"WidgetView"]||[n containsString:@"PageControl"]){SetAlpha(v,a);return;}for(UIView*x in v.subviews)WalkLists(x,a);}
static id Content(){return Msg(RootController(),@"contentView");}
static id CurrentList(){id r=RootController();for(NSString*s in @[@"currentIconListView",@"iconListView",@"currentListView"]){id v=Msg(r,s);if(v)return v;}return nil;}
static id DockList(){id r=RootController();for(NSString*s in @[@"dockListView",@"dockView"]){id v=Msg(r,s);if(v)return v;}return nil;}
static id DockView(){id c=Content();return Msg(c,@"dockView")?:DockList();}
static id FloatingWindow(){for(UIWindow*w in Windows())if(Has(w,@"SBFloatingDockWindow"))return w;return nil;}
static void Floating(BOOL show){id w=FloatingWindow(),r=Msg(w,@"floatingDockRootViewController");SEL s=NSSelectorFromString(@"setPresentationProgress:animated:interactive:withCompletion:");if(r&&[r respondsToSelector:s])((void(*)(id,SEL,double,BOOL,BOOL,id))objc_msgSend)(r,s,show?1.0:0.0,YES,NO,nil);preventDock=!show;}
static void Background(id d,CGFloat a){SEL s=NSSelectorFromString(@"setBackgroundAlpha:");if(d&&[d respondsToSelector:s])((void(*)(id,SEL,double))objc_msgSend)(d,s,a);}
static void Status(BOOL h){id w=nil;@try{w=[UIApplication.sharedApplication valueForKey:@"statusBarWindow"];}@catch(id e){}if(w)BoolMsg(w,@"setHidden:",h);for(UIWindow*x in Windows())if(Has(x,@"StatusBar"))x.hidden=h;}
static void Page(BOOL h){id r=RootController();BoolMsg(r,@"setPageControlHidden:",h);id c=Content();BoolMsg(c,@"setPageControlHidden:",h);}
static void Restore(){for(UIView*v in saved){NSNumber*n=[saved objectForKey:v];if(v&&n)v.alpha=n.doubleValue;}[saved removeAllObjects];Background(DockView(),1);Floating(YES);Page(NO);Status(NO);applied=NO;}
static void Apply(){Load();if(!enabled)return;Restore();id cur=CurrentList(),dock=DockList(),content=Content();[UIView animateWithDuration:.7 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{SetInteractiveAlpha(cur,alpha);WalkLists(content,alpha);if(hideDock){SetInteractiveAlpha(dock,alpha);Background(DockView(),alpha);Floating(NO);}if(hideDockSearch)for(UIView*v in [DockView() subviews])if(Has(v,@"DSSearchBar")||Has(v,@"MPAScrollView")||Has(v,@"MTMaterialView")||Has(v,@"UILabel"))SetAlpha(v,alpha);Page(YES);if(hideStatus)Status(YES);}completion:nil];applied=YES;}
static void ScheduleOnMain(){Load();[timer invalidate];timer=nil;Restore();if(enabled)timer=[NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(__unused NSTimer*t){Apply();}];}
static void Schedule(){if(NSThread.isMainThread)ScheduleOnMain();else dispatch_async(dispatch_get_main_queue(),^{ScheduleOnMain();});}
// 触摸事件分发前必须同步恢复，否则首个 touch 已经错过分页手势容器。
static void InteractNow(){if(NSThread.isMainThread)ScheduleOnMain();else dispatch_sync(dispatch_get_main_queue(),^{ScheduleOnMain();});}
static void Changed(__unused CFNotificationCenterRef c,__unused void*o,__unused CFStringRef n,__unused const void*x,__unused CFDictionaryRef i){Schedule();}
%hook SpringBoard
-(void)applicationDidFinishLaunching:(id)a{%orig;CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,Changed,EVNotify,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);Schedule();}
-(void)frontDisplayDidChange:(id)a{%orig;if(a){[timer invalidate];timer=nil;Restore();}else Schedule();}
%end
%hook SBHomeScreenWindow
-(void)sendEvent:(UIEvent*)e{if(e.allTouches.count||e.type==UIEventTypePresses)InteractNow();%orig;}
%end
%hook SBUIController
-(void)handleHomeButtonSinglePressUp{Schedule();%orig;}-(void)handleHomeButtonDoublePressDown{Schedule();%orig;}
%end
%hook CSCoverSheetViewController
-(void)finishUIUnlockFromSource:(NSInteger)s{%orig;Schedule();}-(void)setInScreenOffMode:(BOOL)o forAutoUnlock:(BOOL)a fromUnlockSource:(NSInteger)s{%orig;if(o){[timer invalidate];timer=nil;Restore();}}
%end
%hook SBFloatingDockRootViewController
-(void)setPresentationProgress:(double)p animated:(BOOL)a interactive:(BOOL)i withCompletion:(id)c{if(preventDock)return;%orig;}
%end
%hook SBFolderController
-(void)setEditing:(BOOL)e animated:(BOOL)a{if(e)Restore();%orig;if(!e)Schedule();}
%end
%ctor{@autoreleasepool{saved=[NSMapTable weakToStrongObjectsMapTable];}}
