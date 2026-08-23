#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "EvanescoPrefs.h"
static NSTimer *timer; static NSMapTable *saved; static BOOL applied;
static BOOL enabled,hideDock,hideStatus,hideDockSearch; static CGFloat alpha; static NSTimeInterval delay;
static void Load(){enabled=[EVRead(@"enabled",@YES)boolValue];hideDock=[EVRead(@"hideDock",@YES)boolValue];hideStatus=[EVRead(@"hideStatusBar",@YES)boolValue];hideDockSearch=[EVRead(@"hideDockSearch",@YES)boolValue];alpha=[EVRead(@"alpha",EVRead(@"fadeAmount",@0.0))doubleValue];delay=MAX(1,[EVRead(@"timeDelay",@6)doubleValue]);}
static BOOL Has(id x,NSString*n){return [NSStringFromClass([x class]) rangeOfString:n options:NSCaseInsensitiveSearch].location!=NSNotFound;}
static NSArray *Windows(){NSMutableArray*a=[NSMutableArray array];for(UIScene*s in UIApplication.sharedApplication.connectedScenes)if([s isKindOfClass:UIWindowScene.class])[a addObjectsFromArray:((UIWindowScene*)s).windows];return a;}
static BOOL InDock(UIView*v){for(UIView*p=v;p;p=p.superview)if(Has(p,@"Dock"))return YES;return NO;}
static BOOL Target(UIView*v){NSString*n=NSStringFromClass(v.class);return [n containsString:@"IconView"]||[n containsString:@"Widget"]||[n containsString:@"PageControl"]||[n containsString:@"SearchPill"]||[n containsString:@"DockView"]||[n containsString:@"IconListView"];}
static void Walk(UIView*v){if(Target(v)){if((!InDock(v)||hideDock)&&(!Has(v,@"Search")||hideDockSearch)){if(![saved objectForKey:v])[saved setObject:@(v.alpha) forKey:v];v.alpha=alpha;}return;}for(UIView*s in v.subviews)Walk(s);}
static void Status(BOOL h){for(UIWindow*w in Windows())for(UIView*v in @[w]){NSMutableArray*q=[NSMutableArray arrayWithObject:v];while(q.count){UIView*x=q.lastObject;[q removeLastObject];if(Has(x,@"StatusBar"))x.hidden=h;[q addObjectsFromArray:x.subviews];}}}
static void Restore(){for(UIView*v in saved){NSNumber*n=[saved objectForKey:v];if(v&&n)v.alpha=n.doubleValue;}[saved removeAllObjects];if(applied&&hideStatus)Status(NO);applied=NO;}
static void Apply(){Load();if(!enabled)return;Restore();for(UIWindow*w in Windows())Walk(w);if(hideStatus)Status(YES);applied=YES;}
static void Schedule(){dispatch_async(dispatch_get_main_queue(),^{Load();[timer invalidate];timer=nil;Restore();if(enabled)timer=[NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(__unused NSTimer*t){Apply();}];});}
static void Changed(__unused CFNotificationCenterRef c,__unused void*o,__unused CFStringRef n,__unused const void*x,__unused CFDictionaryRef i){Schedule();}
%hook SpringBoard
-(void)applicationDidFinishLaunching:(id)a{%orig;CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,Changed,EVNotify,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);Schedule();}
-(void)frontDisplayDidChange:(id)a{%orig;if(a){[timer invalidate];timer=nil;Restore();}else Schedule();}
%end
%hook SBHomeScreenWindow
-(void)sendEvent:(UIEvent*)e{if(e.allTouches.count||e.type==UIEventTypePresses)Schedule();%orig;}
%end
%hook SBUIController
-(void)handleHomeButtonSinglePressUp{Schedule();%orig;}
-(void)handleHomeButtonDoublePressDown{Schedule();%orig;}
%end
%hook CSCoverSheetViewController
-(void)finishUIUnlockFromSource:(NSInteger)s{%orig;Schedule();}
-(void)setInScreenOffMode:(BOOL)o forAutoUnlock:(BOOL)a fromUnlockSource:(NSInteger)s{%orig;if(o){[timer invalidate];timer=nil;Restore();}}
%end
%ctor{@autoreleasepool{saved=[NSMapTable weakToStrongObjectsMapTable];}}
