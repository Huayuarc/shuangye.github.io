#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import "SCCaptureManager.h"
#import "SCPaths.h"

static NSTimeInterval SCUpTime=0, SCDownTime=0;
static NSTimeInterval SCUpHandled=0, SCDownHandled=0; // 同一按键多入口防重复

// 单一相机所有者：仅在 SpringBoard 宿主中执行捕获，避免多进程各自建会话。
static BOOL SCIsSpringBoard(void) {
    NSString *proc=[[NSProcessInfo processInfo] processName];
    return [proc isEqualToString:@"SpringBoard"];
}
static BOOL SCEnabled(void) { id v=SCReadPreferences()[@"Enabled"]; return v?[v boolValue]:NO; }
static void SCImmediateHaptic(void) {
    id value=SCReadPreferences()[@"HapticFeedback"];
    if(value && ![value boolValue]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ AudioServicesPlaySystemSound(1519); });
}

static void SCTrigger(BOOL video) {
    if(!SCEnabled()) return;
    // 双击动作被接受时立即反馈，不等待相机会话或文件保存回调。
    SCImmediateHaptic();
    SCCaptureManager *m=[SCCaptureManager shared];
    if(video) [m toggleVideo]; else [m takePhoto];
}

// 音量按键归口：兼容不同 iOS 的多个入口。
// 同一物理按键会在极短时间内产生多个 selector 回调，仅过滤 55ms 内重复；
// 真实双击支持约 70–650ms，触发后清空状态避免三击重复。
static void SCPress(BOOL up, NSTimeInterval now) {
    NSTimeInterval lastHandled = up?SCUpHandled:SCDownHandled;
    if (now-lastHandled < 0.055) return;
    if (up) SCUpHandled=now; else SCDownHandled=now;

    NSTimeInterval last = up?SCUpTime:SCDownTime;
    NSTimeInterval interval = now-last;
    BOOL isDouble = (last>0 && interval>=0.07 && interval<=0.65);
    if (isDouble) {
        if (up) SCUpTime=0; else SCDownTime=0;
    } else {
        if (up) SCUpTime=now; else SCDownTime=now;
    }

    NSDictionary *p=SCReadPreferences();
    if(!SCIsSpringBoard()||!SCEnabled()||![p[@"UseVolumeButtons"] ?: @YES boolValue]) return;
    if (!isDouble) return;
    NSString *action = up ? p[@"VolumeUpAction"] : p[@"VolumeDownAction"];
    if (![action isKindOfClass:[NSString class]] || action.length==0) action = up?@"video":@"photo";
    if ([action isEqualToString:@"video"]) SCTrigger(YES);
    else if ([action isEqualToString:@"photo"]) SCTrigger(NO);
    // off 或未知值不执行
}

// 运行时动态 Hook：严格按实际所属类安装，类/selector 不存在时安全跳过。
#import <substrate.h>
#import <objc/runtime.h>

static void (*OrigIncreaseVolume)(id,SEL)=NULL,(*OrigDecreaseVolume)(id,SEL)=NULL;
static void (*OrigIncreasePressed)(id,SEL)=NULL,(*OrigDecreasePressed)(id,SEL)=NULL;
static void (*OrigIncreaseModifiers)(id,SEL,id)=NULL,(*OrigDecreaseModifiers)(id,SEL,id)=NULL;

static void HookIncreaseVolume(id self,SEL cmd){ if(OrigIncreaseVolume)OrigIncreaseVolume(self,cmd);SCPress(YES,NSProcessInfo.processInfo.systemUptime); }
static void HookDecreaseVolume(id self,SEL cmd){ if(OrigDecreaseVolume)OrigDecreaseVolume(self,cmd);SCPress(NO,NSProcessInfo.processInfo.systemUptime); }
static void HookIncreasePressed(id self,SEL cmd){ if(OrigIncreasePressed)OrigIncreasePressed(self,cmd);SCPress(YES,NSProcessInfo.processInfo.systemUptime); }
static void HookDecreasePressed(id self,SEL cmd){ if(OrigDecreasePressed)OrigDecreasePressed(self,cmd);SCPress(NO,NSProcessInfo.processInfo.systemUptime); }
static void HookIncreaseModifiers(id self,SEL cmd,id modifiers){ if(OrigIncreaseModifiers)OrigIncreaseModifiers(self,cmd,modifiers);SCPress(YES,NSProcessInfo.processInfo.systemUptime); }
static void HookDecreaseModifiers(id self,SEL cmd,id modifiers){ if(OrigDecreaseModifiers)OrigDecreaseModifiers(self,cmd,modifiers);SCPress(NO,NSProcessInfo.processInfo.systemUptime); }

static BOOL SCHookIfPresent(Class cls,NSString *name,IMP replacement,IMP *original){
    if(!cls)return NO;SEL sel=NSSelectorFromString(name);if(!class_getInstanceMethod(cls,sel))return NO;
    MSHookMessageEx(cls,sel,replacement,original);return YES;
}
static void SCInstallVolumeHooks(void){
    static BOOL traditionalInstalled=NO,pressedInstalled=NO,hardwareInstalled=NO;
    Class volume=NSClassFromString(@"SBVolumeControl");if(!volume)volume=NSClassFromString(@"VolumeControl");
    if(volume&&!traditionalInstalled){BOOL a=SCHookIfPresent(volume,@"increaseVolume",(IMP)HookIncreaseVolume,(IMP*)&OrigIncreaseVolume);BOOL b=SCHookIfPresent(volume,@"decreaseVolume",(IMP)HookDecreaseVolume,(IMP*)&OrigDecreaseVolume);traditionalInstalled=a||b;}
    if(volume&&!pressedInstalled){BOOL a=SCHookIfPresent(volume,@"increaseVolumePressed",(IMP)HookIncreasePressed,(IMP*)&OrigIncreasePressed);BOOL b=SCHookIfPresent(volume,@"decreaseVolumePressed",(IMP)HookDecreasePressed,(IMP*)&OrigDecreasePressed);pressedInstalled=a||b;}
    Class actions=NSClassFromString(@"SBVolumeHardwareButtonActions");
    if(actions&&!hardwareInstalled){BOOL a=SCHookIfPresent(actions,@"volumeIncreasePressDownWithModifiers:",(IMP)HookIncreaseModifiers,(IMP*)&OrigIncreaseModifiers);BOOL b=SCHookIfPresent(actions,@"volumeDecreasePressDownWithModifiers:",(IMP)HookDecreaseModifiers,(IMP*)&OrigDecreaseModifiers);hardwareInstalled=a||b;}
    NSMutableArray *installed=[NSMutableArray array];if(traditionalInstalled)[installed addObject:@"传统音量API"];if(pressedInstalled)[installed addObject:@"Pressed API"];if(hardwareInstalled)[installed addObject:@"iOS17 Hardware API"];
    SCWritePreference(@"ButtonHookStatus",installed.count?[installed componentsJoinedByString:@" + "]:@"等待系统音量类加载");
    notify_post("com.spark.SneakyCam.actionstatechanged");
}
static void SCScheduleVolumeHookRetries(void){
    SCInstallVolumeHooks();
    for(NSNumber *delayNumber in @[@1.0,@3.0,@8.0]) { NSTimeInterval delay=delayNumber.doubleValue; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{SCInstallVolumeHooks();}); }
}


// 屏幕前方绿色录像状态点：仅 SpringBoard 创建，不接收触摸、不强制点亮屏幕。
static UIWindow *SCIndicatorWindow=nil;
static UIView *SCIndicatorDot=nil;
static void SCLayoutIndicator(void){
    if(!SCIndicatorWindow||!SCIndicatorDot)return;
    CGRect bounds=UIScreen.mainScreen.bounds;SCIndicatorWindow.frame=bounds;
    CGFloat diameter=12.0;CGFloat top=MAX(10.0,SCIndicatorWindow.safeAreaInsets.top+4.0);CGFloat right=18.0;
    SCIndicatorDot.frame=CGRectMake(CGRectGetWidth(bounds)-right-diameter,top,diameter,diameter);
    SCIndicatorDot.layer.cornerRadius=diameter/2.0;
}
static void SCUpdateIndicator(void){
    if(!SCIsSpringBoard())return;
    NSDictionary *p=SCReadPreferences();BOOL enabled=[p[@"Enabled"]?:@NO boolValue];BOOL recording=[p[@"Recording"]?:@NO boolValue];BOOL allowed=[p[@"RecordingIndicator"]?:@YES boolValue];
    if(!SCIndicatorWindow){
        SCIndicatorWindow=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];SCIndicatorWindow.backgroundColor=UIColor.clearColor;SCIndicatorWindow.userInteractionEnabled=NO;SCIndicatorWindow.windowLevel=UIWindowLevelAlert+100.0;
        UIViewController *root=[UIViewController new];root.view.backgroundColor=UIColor.clearColor;root.view.userInteractionEnabled=NO;SCIndicatorWindow.rootViewController=root;
        SCIndicatorDot=[UIView new];SCIndicatorDot.backgroundColor=[UIColor colorWithRed:0.12 green:0.82 blue:0.32 alpha:1.0];SCIndicatorDot.layer.shadowColor=UIColor.blackColor.CGColor;SCIndicatorDot.layer.shadowOpacity=.28;SCIndicatorDot.layer.shadowRadius=2;[root.view addSubview:SCIndicatorDot];SCLayoutIndicator();
    }
    SCIndicatorWindow.hidden=!(enabled&&recording&&allowed);
    if(!SCIndicatorWindow.hidden)SCLayoutIndicator();
}
static void SCIndicatorNotification(CFNotificationCenterRef c,void*o,CFStringRef n,const void*obj,CFDictionaryRef u){dispatch_async(dispatch_get_main_queue(),^{SCUpdateIndicator();});}

// 音量键动作的 Darwin 广播
static void SCActionNotification(CFNotificationCenterRef c, void*o, CFStringRef n, const void*obj, CFDictionaryRef u) {
    if(!SCIsSpringBoard()) return;
    NSString *s=(__bridge NSString*)n;
    if([s hasSuffix:@"startstopvideo"]) SCTrigger(YES);
    else { SCImmediateHaptic(); [[SCCaptureManager shared] takePhoto]; }
}
// 关闭总开关时立即停止并释放相机
static void SCEnabledNotification(CFNotificationCenterRef c, void*o, CFStringRef n, const void*obj, CFDictionaryRef u) {
    if(!SCEnabled()) [[SCCaptureManager shared] stopAndRelease];
}

%ctor {
    @autoreleasepool {
        SCMigratePreferencesIfNeeded();
        if(SCIsSpringBoard()) SCScheduleVolumeHookRetries();
        CFNotificationCenterRef dc=CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc,NULL,SCActionNotification,CFSTR("com.spark.SneakyCam.takephoto"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc,NULL,SCActionNotification,CFSTR("com.spark.SneakyCam.startstopvideo"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc,NULL,SCEnabledNotification,CFSTR("com.spark.SneakyCam.enabledchanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc,NULL,SCIndicatorNotification,CFSTR("com.spark.SneakyCam.recordingstatechanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc,NULL,SCIndicatorNotification,CFSTR("com.spark.SneakyCam.enabledchanged"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        if(SCIsSpringBoard()) dispatch_async(dispatch_get_main_queue(),^{SCUpdateIndicator();});
        if(!SCEnabled()) [[SCCaptureManager shared] stopAndRelease];
    }
}
