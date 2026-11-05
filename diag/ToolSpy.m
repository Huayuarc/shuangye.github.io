// 注入 CCSIMTool 进程，记录它自己调用 CTCellularPlanManager 时看到的东西。
// 只记录，不改行为。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdio.h>
#import <sys/stat.h>
#import <stdarg.h>
#import <unistd.h>

static FILE *gFp;

static void Spy(const char *fmt, ...)
{
    if (!gFp) {
        mkdir("/var/mobile/tmp", 0755);
        gFp = fopen("/var/mobile/tmp/ToolSpy.log", "a");
    }
    if (!gFp) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(gFp, fmt, ap);
    va_end(ap);
    fputc('\n', gFp);
    fflush(gFp);
}

typedef void (*MSHookFn)(void *, void *, void **);
static MSHookFn gHook;

static id (*orig_planItemsShouldUpdate)(id, SEL, BOOL);
static id (*orig_didSelect)(id, SEL, id, BOOL);

static id spy_planItemsShouldUpdate(id self, SEL cmd, BOOL shouldUpdate)
{
    id r = orig_planItemsShouldUpdate(self, cmd, shouldUpdate);
    Spy("planItemsShouldUpdate:%d -> %s count=%ld",
        (int)shouldUpdate, r ? class_getName(object_getClass(r)) : "nil",
        r ? (long)[r count] : -1L);
    if ([r isKindOfClass:[NSArray class]]) {
        for (NSUInteger i = 0; i < [r count]; i++) {
            id item = r[i];
            Spy("   [%lu] %s selected=%d", (unsigned long)i,
                class_getName(object_getClass(item)),
                [item respondsToSelector:@selector(isSelected)] ? (int)((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isSelected)) : -1);
        }
    }
    return r;
}

static id spy_didSelect(id self, SEL cmd, id item, BOOL enable)
{
    Spy("didSelectPlanItem isEnable:%d item=%s", (int)enable,
        item ? class_getName(object_getClass(item)) : "nil");
    id r = orig_didSelect(self, cmd, item, enable);
    Spy("  -> %s", r ? [[r description] UTF8String] : "nil");
    return r;
}

__attribute__((constructor)) static void SpyInit(void)
{
    Spy("injected pid %d", getpid());
    dlopen("/System/Library/PrivateFrameworks/CellularPlanManager.framework/CellularPlanManager", RTLD_LAZY);
    gHook = (MSHookFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!gHook) { Spy("no MSHookFunction"); return; }
    Class pm = objc_getClass("CTCellularPlanManager");
    if (!pm) { Spy("no CTCellularPlanManager"); return; }
    Method m1 = class_getInstanceMethod(pm, @selector(planItemsShouldUpdate:));
    if (m1) gHook((void *)method_getImplementation(m1), (void *)spy_planItemsShouldUpdate,
                  (void **)&orig_planItemsShouldUpdate);
    Method m2 = class_getInstanceMethod(pm, @selector(didSelectPlanItem:isEnable:));
    if (m2) gHook((void *)method_getImplementation(m2), (void *)spy_didSelect,
                  (void **)&orig_didSelect);
    Spy("hooks installed m1=%p m2=%p", (void *)m1, (void *)m2);
}
