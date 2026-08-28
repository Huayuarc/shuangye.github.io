#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>
static atomic_bool gForce120=false,gCaptured=false;static int gToken=0;static BOOL Active(void){return atomic_load(&gForce120)&&!atomic_load(&gCaptured);}static void Reload(void){BOOL f=NO;CPUthermalReadRefreshRateState(&f);atomic_store(&gForce120,f);}
@interface CADynamicFrameRateSource:NSObject@end
@interface CAFrameRateRangeGroup:NSObject@end
static void SetFloat(id o,const char*n,float v){SEL s=NSSelectorFromString(S(n));if(o&&[o respondsToSelector:s])((void(*)(id,SEL,float))objc_msgSend)(o,s,v);}
static void ApplyWindowServer(void){if(!Active())return;Class c=NSClassFromString(S("CAWindowServer"));SEL ss=NSSelectorFromString(S("server"));id server=[c respondsToSelector:ss]?((id(*)(id,SEL))objc_msgSend)(c,ss):nil;SEL ds=NSSelectorFromString(S("displays"));NSArray*a=[server respondsToSelector:ds]?((id(*)(id,SEL))objc_msgSend)(server,ds):nil;for(id d in a){SetFloat(d,"setMinimumRefreshRate:",120);SetFloat(d,"setMaximumRefreshRate:",120);SetFloat(d,"setIdealRefreshRate:",120);}}
%group System120Hooks
%hook UIScreen
- (NSInteger)maximumFramesPerSecond{return Active()?120:%orig;}
%end
%hook CADisplayLink
+ (CADisplayLink*)displayLinkWithTarget:(id)t selector:(SEL)s{CADisplayLink*l=%orig;if(Active())l.preferredFrameRateRange=CAFrameRateRangeMake(10,120,120);return l;}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)r{if(Active()){r.maximum=120;r.preferred=120;if(r.minimum<=0||r.minimum>120)r.minimum=10;}%orig(r);}
%end
%hook CADynamicFrameRateSource
- (void)setPreferredFrameRateRange:(CAFrameRateRange)r{if(Active())r=CAFrameRateRangeMake(120,120,120);%orig(r);}
- (CAFrameRateRange)preferredFrameRateRange{CAFrameRateRange r=%orig;if(Active())r=CAFrameRateRangeMake(120,120,120);return r;}
%end
%hook CAFrameRateRangeGroup
- (CAFrameRateRange)arbitratedRange{CAFrameRateRange r=%orig;if(Active())r=CAFrameRateRangeMake(120,120,120);return r;}
%end
%end
%ctor{@autoreleasepool{NSString*bid=NSBundle.mainBundle.bundleIdentifier;BOOL target=[bid isEqualToString:S("com.apple.springboard")]||[bid isEqualToString:S("com.apple.Preferences")];if(!target)return;Reload();%init(System120Hooks);dispatch_async(dispatch_get_main_queue(),^{atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);if(!atomic_load(&gCaptured))ApplyWindowServer();[NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification*n){atomic_store(&gCaptured,UIScreen.mainScreen.isCaptured);if(!atomic_load(&gCaptured))ApplyWindowServer();}];});notify_register_dispatch(kCPUthermalRefreshRateNotifC,&gToken,dispatch_get_main_queue(),^(int t){(void)t;Reload();if(!atomic_load(&gCaptured))ApplyWindowServer();});}}
