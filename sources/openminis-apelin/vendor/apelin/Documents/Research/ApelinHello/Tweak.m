// ApelinHello: when SpringBoard finishes launching, show "Hello World".
// Built on the device by the retargeted toolchain; no substrate API needed.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

static void (*originalDidFinish)(id, SEL, id);
static UIWindow *helloWindow;

static void showHello(void) {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)candidate; break; }
    }
    if (scene == nil) { os_log(OS_LOG_DEFAULT, "ApelinHello: no window scene"); return; }
    helloWindow = [[UIWindow alloc] initWithWindowScene:scene];
    helloWindow.windowLevel = UIWindowLevelAlert + 1;
    helloWindow.rootViewController = [UIViewController new];
    helloWindow.hidden = NO;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hello World"
                                                                   message:@"Built on this device by Apelin."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        helloWindow.hidden = YES;
        helloWindow = nil;
    }]];
    [helloWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    os_log(OS_LOG_DEFAULT, "ApelinHello: alert shown");
}

static void replacementDidFinish(id self, SEL _cmd, id application) {
    originalDidFinish(self, _cmd, application);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ showHello(); });
}

__attribute__((constructor)) static void ApelinHelloInit(void) {
    os_log(OS_LOG_DEFAULT, "ApelinHello: loaded into %{public}s", getprogname());
    Class springBoard = objc_getClass("SpringBoard");
    Method method = class_getInstanceMethod(springBoard, @selector(applicationDidFinishLaunching:));
    if (method == NULL) { os_log(OS_LOG_DEFAULT, "ApelinHello: no applicationDidFinishLaunching:"); return; }
    originalDidFinish = (void (*)(id, SEL, id))method_setImplementation(method, (IMP)replacementDidFinish);
}
