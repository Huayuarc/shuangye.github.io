// 把真正要发布的 dylib 载进一个普通进程，确认：
//  1) 构造/重试路径能把 hook 打到真的 CoreTelephonyClient 上；
//  2) 打上之后，真实调用照常快速返回（守卫没有改变正常行为）。
// 用编译进主程序的 MSHookMessageEx 代替 substrate。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>

void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *result)
{
    Method m = class_getInstanceMethod(cls, selector);
    if (!m) {
        if (result) *result = NULL;
        return;
    }
    IMP old = method_getImplementation(m);
    method_setImplementation(m, replacement);
    if (result) *result = old;
    printf("[stub] hooked -[%s %s]\n", class_getName(cls), sel_getName(selector));
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        const char *path = argc > 1 ? argv[1] : "./CCSIMFix.dylib";
        void *h = dlopen(path, RTLD_NOW);
        if (!h) {
            printf("FAIL dlopen: %s\n", dlerror());
            return 1;
        }
        printf("[1] dylib loaded: %s\n", path);

        BOOL (*installed)(void) = (BOOL (*)(void))dlsym(h, "CCSIMFixHooksInstalled");
        if (!installed) { printf("FAIL: no CCSIMFixHooksInstalled export\n"); return 2; }

        for (int i = 0; i < 20 && !installed(); i++) usleep(100 * 1000);
        printf("[2] hooks installed: %s\n", installed() ? "yes" : "no");
        if (!installed()) return 3;

        dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
        Class clientClass = objc_getClass("CoreTelephonyClient");
        if (!clientClass) { printf("FAIL: no CoreTelephonyClient\n"); return 4; }

        id client = ((id (*)(id, SEL, id))objc_msgSend)(
            [clientClass alloc], NSSelectorFromString(@"initWithQueue:"),
            dispatch_get_global_queue(0, 0));

        SEL sel = NSSelectorFromString(@"getSIMStatus:error:");
        IMP imp = [client methodForSelector:sel];
        NSError *e = nil;
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        id status = ((id (*)(id, SEL, id, NSError **))imp)(client, sel, nil, &e);
        double dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("[3] hooked getSIMStatus -> %s in %.3fs (%s)\n",
               status ? [[status description] UTF8String] : "nil", dt,
               e ? [[e localizedDescription] UTF8String] : "no error");
        if (dt > 3.0) return 5;

        printf("ALL OK\n");
    }
    return 0;
}
