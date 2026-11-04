// 守卫逻辑的离线自测：和 Tweak.m 一起编进一个可执行文件跑，
// 用自己实现的 MSHookMessageEx（method_setImplementation）代替 substrate。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>

void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *result)
{
    Method m = class_getInstanceMethod(cls, selector);
    if (!m) {
        printf("[stub] no method %s on %s\n", sel_getName(selector), class_getName(cls));
        if (result) *result = NULL;
        return;
    }
    IMP old = method_getImplementation(m);
    method_setImplementation(m, replacement);
    if (result) *result = old;
    printf("[stub] hooked -[%s %s]\n", class_getName(cls), sel_getName(selector));
}

#ifdef CCSIMFIX_TESTING
BOOL CCSIMFixHooksInstalled(void);
void CCSIMFixInstallNow(void);
id CCSIMFixTestGuard(IMP imp, id target, SEL cmd, id arg, NSError **err,
                     const char *what, BOOL owned);
#endif

// 一个“永不返回”的假实现，模拟 iOS 17 上不回复的 CommCenter
static id slow_imp(id self, SEL cmd, id arg, NSError **err)
{
    sleep(30);
    return @"slow";
}

static id fast_imp(id self, SEL cmd, id arg, NSError **err)
{
    return @"fast";
}

int main(void)
{
    @autoreleasepool {
        NSLog(@"harness start");

        // 1) 普通返回：应立刻拿到值
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        NSError *e = nil;
        id v = CCSIMFixTestGuard((IMP)fast_imp, (id)@"target", @selector(copyLabel:error:),
                                 (id)@"arg", &e, "fast", NO);
        double dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("[1] fast: value=%s elapsed=%.3fs\n", [[v description] UTF8String], dt);
        if (![v isEqualToString:@"fast"]) { printf("FAIL step 1\n"); return 1; }

        // 2) 卡住不返回：应在 ~2s 后返回 nil（不是永远挂住）
        t0 = CFAbsoluteTimeGetCurrent();
        e = nil;
        v = CCSIMFixTestGuard((IMP)slow_imp, (id)@"target", @selector(copyLabel:error:),
                              (id)@"arg", &e, "slow#1", NO);
        dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("[2] slow#1: value=%s err=%s elapsed=%.3fs\n",
               v ? "non-nil" : "nil", [[e description] UTF8String], dt);
        if (v || dt < 1.5 || dt > 3.5) { printf("FAIL step 2\n"); return 2; }

        // 3) 再卡一次 → 触发熔断
        t0 = CFAbsoluteTimeGetCurrent();
        e = nil;
        v = CCSIMFixTestGuard((IMP)slow_imp, (id)@"target", @selector(copyLabel:error:),
                              (id)@"arg", &e, "slow#2", NO);
        dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("[3] slow#2: elapsed=%.3fs\n", dt);
        if (v || dt < 1.5 || dt > 3.5) { printf("FAIL step 3\n"); return 3; }

        // 4) 熔断期内立刻返回
        t0 = CFAbsoluteTimeGetCurrent();
        e = nil;
        v = CCSIMFixTestGuard((IMP)slow_imp, (id)@"t", @selector(copyLabel:error:),
                              (id)@"arg", &e, "slow#3", NO);
        dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("[4] cool-down: elapsed=%.4fs\n", dt);
        if (v || dt > 0.3) { printf("FAIL step 4\n"); return 4; }

        // 5) 真实 CoreTelephony 调用经过守卫（有无权限都应快速返回，不挂）
        dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
        Class clientClass = objc_getClass("CoreTelephonyClient");
        Class ctxClass = objc_getClass("CTXPCServiceSubscriptionContext");
        printf("[5] CoreTelephonyClient=%p CTXPCServiceSubscriptionContext=%p\n",
               (void *)clientClass, (void *)ctxClass);
        if (clientClass && ctxClass) {
            id client = ((id (*)(id, SEL, id))objc_msgSend)([clientClass alloc], NSSelectorFromString(@"initWithQueue:"), dispatch_get_global_queue(0, 0));
            NSError *e2 = nil;
            SEL sel = NSSelectorFromString(@"getSIMStatus:error:");
            IMP imp = [client methodForSelector:sel];
            t0 = CFAbsoluteTimeGetCurrent();
            id status = ((id (*)(id, SEL, id, NSError **))imp)(client, sel, nil, &e2);
            dt = CFAbsoluteTimeGetCurrent() - t0;
            printf("[5] getSIMStatus(nil ctx) -> %s in %.3fs (%s)\n",
                   status ? [[status description] UTF8String] : "nil", dt,
                   e2 ? [[e2 localizedDescription] UTF8String] : "no error");
            if (dt > 4.0) { printf("FAIL step 5\n"); return 5; }
        }

        printf("[6] hooks installed in this process: %s\n",
               CCSIMFixHooksInstalled() ? "yes" : "no");
        if (!CCSIMFixHooksInstalled()) {
            printf("[6] retrying install synchronously...\n");
            CCSIMFixInstallNow();
            printf("[6] after retry: %s\n", CCSIMFixHooksInstalled() ? "yes" : "no");
        }
        if (!CCSIMFixHooksInstalled()) { printf("FAIL step 6\n"); return 6; }

        printf("ALL OK\n");
    }
    return 0;
}
