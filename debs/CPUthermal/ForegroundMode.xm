#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CPUthermalPaths.h>

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

static void CPUthermalReportCurrentApplication(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application.applicationState != UIApplicationStateActive) return;
    CPUthermalPostForegroundBundleID(CPUthermalOwnBundleID());
}

static void CPUthermalClearCurrentApplication(void) {
    CPUthermalClearForegroundBundleIDIfCurrent(CPUthermalOwnBundleID());
}

// 部分 RootHide 注入配置会阻止目标应用加载通用 dylib；SpringBoard 作为系统级
// 真值源轮询当前前台应用，确保指定应用功能不依赖目标应用自身成功注入。
static NSString *CPUthermalSpringBoardFrontmostBundleID(void) {
    id springBoard = [UIApplication sharedApplication];
    id application = nil;
    const char *frontSelectors[] = {"_accessibilityFrontMostApplication", "accessibilityFrontMostApplication", "frontmostApplication", NULL};
    for (int i = 0; frontSelectors[i] && !application; i++) {
        SEL selector = sel_registerName(frontSelectors[i]);
        if ([springBoard respondsToSelector:selector]) application = ((id (*)(id, SEL))objc_msgSend)(springBoard, selector);
    }
    if (!application) {
        Class controllerClass = objc_getClass("SBApplicationController");
        SEL sharedSelector = sel_registerName("sharedInstance");
        id controller = [controllerClass respondsToSelector:sharedSelector] ? ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector) : nil;
        SEL frontSelector = sel_registerName("frontmostApplication");
        if ([controller respondsToSelector:frontSelector]) application = ((id (*)(id, SEL))objc_msgSend)(controller, frontSelector);
    }
    const char *idSelectors[] = {"bundleIdentifier", "displayIdentifier", "applicationIdentifier", NULL};
    return CPUthermalStringFromObject(application, idSelectors);
}

static void CPUthermalStartSpringBoardMonitor(void) {
    __block uint64_t lastHash = UINT64_MAX;
    void (^poll)(void) = ^{
        NSString *bundleID = CPUthermalSpringBoardFrontmostBundleID();
        uint64_t hash = CPUthermalBundleIDHash(bundleID);
        if (hash == lastHash) return;
        lastHash = hash;
        CPUthermalPostForegroundBundleID(bundleID);
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
    if (bundleID.length) CPUthermalPostForegroundBundleID(bundleID);
    %orig;
    if (bundleID.length) CPUthermalPostForegroundBundleID(bundleID);
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
            CPUthermalReportCurrentApplication();
        });
    }
}
