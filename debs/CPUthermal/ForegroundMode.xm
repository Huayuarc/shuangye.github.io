#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CPUthermalPaths.h>

static NSInteger gLastPublishedRuntimeMode = -1;

static BOOL CPUthermalBundleUsesLowPower(NSString *bundleID) {
    if (!bundleID.length) return NO;
    NSDictionary *prefs=CPUthermalReadPrefs();
    NSArray *selected=[prefs[S("lowPowerApps")] isKindOfClass:[NSArray class]] ? prefs[S("lowPowerApps")] : nil;
    return [selected containsObject:bundleID];
}

static NSString *CPUthermalSavedPowerMode(void) {
    id mode=CPUthermalReadPrefs()[S("powerMode")];
    return [mode isKindOfClass:[NSString class]] ? mode : S(kCPUthermalFullPowerModeC);
}

static void CPUthermalPublishRuntimeModeForBundleID(NSString *bundleID) {
    if (!bundleID.length) return;
    CPUthermalPostForegroundBundleID(bundleID);
    BOOL low=CPUthermalBundleUsesLowPower(bundleID) || [[CPUthermalSavedPowerMode() lowercaseString] isEqualToString:S("lowpower")];
    NSInteger desired=low?1:0;
    BOOL postedLow=NO;
    if(gLastPublishedRuntimeMode==desired && CPUthermalReadPostedPowerMode(&postedLow) && postedLow==low)return;
    gLastPublishedRuntimeMode=desired;
    CPUthermalPostPowerMode(low?S(kCPUthermalLowPowerModeC):S(kCPUthermalFullPowerModeC));
}

static NSString *CPUthermalOwnBundleID(void) {
    return [[NSBundle mainBundle] bundleIdentifier];
}

static NSString *CPUthermalStringFromObject(id object, const char **selectors) {
    for (int i = 0; object && selectors[i]; i++) {
        SEL selector = sel_registerName(selectors[i]);
        if (![object respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }
    return nil;
}

static void CPUthermalPublishBundleIDRepeatedly(NSString *bundleID) {
    if (!bundleID.length) return;
    CPUthermalPublishRuntimeModeForBundleID(bundleID);
    // 前台切换期间 SpringBoard 场景状态仍会变化，短脉冲确认可避免旧进程后台通知覆盖新值。
    for (NSNumber *delay in @[@0.10, @0.35, @0.80]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIApplication *application=[UIApplication sharedApplication];
            if (application.applicationState==UIApplicationStateActive) CPUthermalPublishRuntimeModeForBundleID(bundleID);
        });
    }
}

static void CPUthermalReportCurrentApplication(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application.applicationState != UIApplicationStateActive) return;
    CPUthermalPublishBundleIDRepeatedly(CPUthermalOwnBundleID());
}

static void CPUthermalClearCurrentApplication(void) {
    if (CPUthermalClearForegroundBundleIDIfCurrent(CPUthermalOwnBundleID())) {
        BOOL low=[[CPUthermalSavedPowerMode() lowercaseString] isEqualToString:S("lowpower")];
        gLastPublishedRuntimeMode=low?1:0;
        CPUthermalPostPowerMode(low?S(kCPUthermalLowPowerModeC):S(kCPUthermalFullPowerModeC));
    }
}

// 部分 RootHide 注入配置会阻止目标应用加载通用 dylib；SpringBoard 作为系统级
// 真值源轮询当前前台应用，确保指定应用功能不依赖目标应用自身成功注入。
static NSString *CPUthermalSpringBoardFrontmostBundleID(void) {
    id springBoard = [UIApplication sharedApplication];
    id application = nil;
    Class controllerClass = objc_getClass("SBApplicationController");
    SEL sharedSelector = sel_registerName("sharedInstance");
    id controller = [controllerClass respondsToSelector:sharedSelector] ? ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector) : nil;

    // 第一优先级：枚举真实处于 foreground 的 SBApplication。避免 UIApplication 的 accessibility
    // selector 在第三方前台时仍返回 SpringBoard 自身，造成低功耗状态每秒来回覆盖。
    SEL runningSelector=sel_registerName("runningApplications");
    id running=[controller respondsToSelector:runningSelector]?((id(*)(id,SEL))objc_msgSend)(controller,runningSelector):nil;
    id springBoardFallback=nil;
    const char *idSelectors[] = {"bundleIdentifier", "displayIdentifier", "applicationIdentifier", NULL};
    if([running isKindOfClass:NSArray.class]) for(id item in running) {
        SEL active=sel_registerName("isProcessForeground");
        if(![item respondsToSelector:active]||!((BOOL(*)(id,SEL))objc_msgSend)(item,active))continue;
        NSString *candidate=CPUthermalStringFromObject(item,idSelectors);
        if(candidate.length&&![candidate isEqualToString:S("com.apple.springboard")]){application=item;break;}
        if(candidate.length)springBoardFallback=item;
    }
    if(!application)application=springBoardFallback;
    if(!application) {
        const char *controllerSelectors[]={"frontmostApplication","_frontmostApplication",NULL};
        for(int i=0;controllerSelectors[i]&&!application;i++) {
            SEL selector=sel_registerName(controllerSelectors[i]);
            if([controller respondsToSelector:selector])application=((id(*)(id,SEL))objc_msgSend)(controller,selector);
        }
    }
    if(!application) {
        const char *frontSelectors[]={"_accessibilityFrontMostApplication","accessibilityFrontMostApplication","frontmostApplication","_frontMostApp","_frontmostApplication",NULL};
        for(int i=0;frontSelectors[i]&&!application;i++) {
            SEL selector=sel_registerName(frontSelectors[i]);
            if([springBoard respondsToSelector:selector])application=((id(*)(id,SEL))objc_msgSend)(springBoard,selector);
        }
    }
    NSString *bundleID=CPUthermalStringFromObject(application,idSelectors);
    if (bundleID.length) return bundleID;

    // iOS 15 scene-based SpringBoard fallback。
    Class managerClass=objc_getClass("SBMainWorkspace");
    SEL mainSelector=sel_registerName("sharedInstance");
    id workspace=[managerClass respondsToSelector:mainSelector]?((id(*)(id,SEL))objc_msgSend)(managerClass,mainSelector):nil;
    const char *workspaceSelectors[]={"frontmostApplication", "_frontmostApplication", NULL};
    for(int i=0;workspaceSelectors[i];i++) {
        SEL selector=sel_registerName(workspaceSelectors[i]);
        if([workspace respondsToSelector:selector]) {
            bundleID=CPUthermalStringFromObject(((id(*)(id,SEL))objc_msgSend)(workspace,selector),idSelectors);
            if(bundleID.length)return bundleID;
        }
    }
    return nil;
}

static void CPUthermalStartSpringBoardMonitor(void) {
    __block uint64_t lastHash = UINT64_MAX;
    void (^poll)(void) = ^{
        NSString *bundleID = CPUthermalSpringBoardFrontmostBundleID();
        // 场景切换期间取不到真值时保持最后状态，等待应用心跳/后台通知；不伪报 SpringBoard。
        if(!bundleID.length)return;
        uint64_t hash = CPUthermalBundleIDHash(bundleID);
        if(hash==lastHash)return;
        lastHash=hash;
        CPUthermalPublishRuntimeModeForBundleID(bundleID);
    };
    poll();
    // 100ms 兜底轮询；应用激活 Hook 仍是主路径，RootHide 阻止目标 App 注入时也能快速识别。
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *timer) { poll(); }];
}

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
- (NSString *)displayIdentifier;
@end

%hook SBApplication
- (void)activate {
    const char *selectors[] = {"bundleIdentifier", "displayIdentifier", "applicationIdentifier", NULL};
    NSString *bundleID = CPUthermalStringFromObject(self, selectors);
    // activate 前先发布，thermalmonitord 可与应用前台切换并行套用低功耗；完成后再确认一次。
    if (bundleID.length) CPUthermalPublishBundleIDRepeatedly(bundleID);
    %orig;
    if (bundleID.length) CPUthermalPublishBundleIDRepeatedly(bundleID);
}
%end

%hook UIApplication
- (void)didBecomeActive {
    %orig;
    if (![CPUthermalOwnBundleID() isEqualToString:S("com.apple.springboard")]) CPUthermalReportCurrentApplication();
}
- (void)didEnterBackground {
    %orig;
    if (![CPUthermalOwnBundleID() isEqualToString:S("com.apple.springboard")]) CPUthermalClearCurrentApplication();
}
%end

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([CPUthermalOwnBundleID() isEqualToString:S("com.apple.springboard")]) {
                CPUthermalStartSpringBoardMonitor();
                return;
            }
            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
            [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) { CPUthermalReportCurrentApplication(); }];
            [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
                dispatch_async(dispatch_get_main_queue(), ^{ CPUthermalReportCurrentApplication(); });
            }];
            [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) { CPUthermalClearCurrentApplication(); }];
            // 应用保持前台期间持续报告，避免几十秒后被其他进程的迟到生命周期通知覆盖。
            [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
                UIApplication *application=UIApplication.sharedApplication;
                if(application.applicationState==UIApplicationStateActive)CPUthermalPublishRuntimeModeForBundleID(CPUthermalOwnBundleID());
            }];
            CPUthermalReportCurrentApplication();
        });
    }
}
