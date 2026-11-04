// CCSIMGuard — 让 CCSIM 控制中心模块在 iOS 17 上不再卡死 SpringBoard。
//
// 背景（签名是本机 iOS 16.1.2 的 CoreTelephony 上实际读出来的）：
//   -[CoreTelephonyClient getSIMStatus:error:]  enc=@32@0:8@16^@24
//   -[CoreTelephonyClient copyLabel:error:]     enc=@32@0:8@16^@24
// 这两个是同步 XPC 调用：内部阻塞等 CommCenter 回复，没有超时。CCSIM 在
// SpringBoard 主线程（下拉控制中心、点击开关时）调用它们。iOS 17 上
// CommCenter 的回复可能永远不来，主线程就永久阻塞，只能强制重启。
//
// 本插件把这类同步取值方法改成“带超时的守卫调用”：真正的调用放到后台
// 队列，调用方最多等 kTimeout 秒；超时就返回安全值（nil + NSError），
// CCSIM 走它自己的失败分支，界面不再冻结。连续超时后进入熔断期，直接
// 返回安全值，免得每次刷新都卡满 2 秒。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <dispatch/dispatch.h>

// substrate 的头文件在两种构建环境里位置不同，符号在安装时用 dlsym 取，
// 这样 dylib 不留下未定义符号（本机 ld 不允许 -undefined dynamic_lookup）。
typedef void (*MSHookFunc)(Class cls, SEL selector, IMP replacement, IMP *result);

static MSHookFunc hookFunction(void)
{
    static MSHookFunc fn;
    if (!fn) fn = (MSHookFunc)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    return fn;
}

#define kSubsystem "com.netskao.ccsim"
#define kTimeout 2.0     // 单次同步调用最长等待
#define kTripAfter 2     // 连续超时几次后熔断
#define kCooldown 30.0   // 熔断持续多久
#define kMaxRetries 40   // 0.5s 一次，最多 20 秒内找到 CoreTelephonyClient

static os_log_t gLog;
static dispatch_queue_t gQueue;
static BOOL gInstalled;
static int gTimeoutStreak;
static CFAbsoluteTime gCoolDownUntil;

static inline void release_(id obj) { [obj release]; }

static NSError *MakeTimeoutError(const char *what)
{
    NSDictionary *info = @{ NSLocalizedDescriptionKey :
                                [NSString stringWithFormat:@"CCSIMGuard: %s timed out", what] };
    return [NSError errorWithDomain:@"com.netskao.ccsim.guard" code:1001 userInfo:info];
}

typedef struct {
    IMP imp;
    id target;
    id arg;
    SEL cmd;
    id result;
    NSError *error;
    dispatch_semaphore_t sem;
} ct_guard_ctx;

static void ct_guard_run(void *p)
{
    ct_guard_ctx *c = (ct_guard_ctx *)p;
    @autoreleasepool {
        NSError *e = nil;
        id (*fn)(id, SEL, id, NSError **) = (id (*)(id, SEL, id, NSError **))c->imp;
        id r = fn(c->target, c->cmd, c->arg, &e);
        [r retain];
        c->result = r;
        c->error = [e retain];
    }
    dispatch_semaphore_signal(c->sem);
}

// 把一次同步调用变成“最多等 kTimeout 秒”。wantOwned 对应 copy 语义的 +1。
static id GuardedCall(IMP imp, id target, SEL cmd, id arg, NSError **errOut,
                      const char *what, BOOL wantOwned)
{
    if (CFAbsoluteTimeGetCurrent() < gCoolDownUntil) {
        // 熔断期：直接给安全值，不再等待
        if (errOut) *errOut = MakeTimeoutError(what);
        return nil;
    }

    ct_guard_ctx *ctx = calloc(1, sizeof(ct_guard_ctx));
    if (!ctx) {
        if (errOut) *errOut = MakeTimeoutError(what);
        return nil;
    }
    ctx->imp = imp;
    ctx->cmd = cmd;
    ctx->target = [target retain];
    ctx->arg = [arg retain];
    ctx->sem = dispatch_semaphore_create(0);

    dispatch_async_f(gQueue, ctx, ct_guard_run);

    long timedOut = dispatch_semaphore_wait(
        ctx->sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimeout * NSEC_PER_SEC)));

    if (timedOut != 0) {
        // 后台那次调用还在跑，ctx 交给它自己收尾：宁可漏一点内存，
        // 也不要在 SpringBoard 里释放一个仍被后台线程引用的结构。
        gTimeoutStreak++;
        if (gTimeoutStreak >= kTripAfter) {
            gTimeoutStreak = 0;
            gCoolDownUntil = CFAbsoluteTimeGetCurrent() + kCooldown;
            os_log_with_type(gLog, OS_LOG_TYPE_ERROR,
                             "CCSIMGuard: %{public}s timed out, cooling down %.0fs",
                             what, kCooldown);
        } else {
            os_log_with_type(gLog, OS_LOG_TYPE_ERROR,
                             "CCSIMGuard: %{public}s timed out after %.1fs", what, kTimeout);
        }
        if (errOut) *errOut = MakeTimeoutError(what);
        return nil;
    }

    gTimeoutStreak = 0;

    id result = ctx->result;
    NSError *err = ctx->error;
    release_(ctx->target);
    release_(ctx->arg);
    dispatch_release(ctx->sem);
    free(ctx);

    if (errOut) *errOut = [err autorelease];
    else [err release];

    if (wantOwned) return result;       // copy 语义：+1 交给调用方
    return [result autorelease];
}

#pragma mark - hooks

#ifdef CCSIMGUARD_TESTING
BOOL CCSIMGuardHooksInstalled(void);
void CCSIMGuardInstallNow(void);
id CCSIMGuardTestGuard(IMP imp, id target, SEL cmd, id arg, NSError **err,
                     const char *what, BOOL owned);
#endif

static id (*orig_getSIMStatus)(id, SEL, id, NSError **);
static id (*orig_copyLabel)(id, SEL, id, NSError **);
static id (*orig_getSubscriptionInfoWithError)(id, SEL, NSError **);
static id (*orig_getMobileEquipmentInfo)(id, SEL, NSError **);

static id hook_getSIMStatus(id self, SEL cmd, id context, NSError **err)
{
    return GuardedCall((IMP)orig_getSIMStatus, self, cmd, context, err,
                       "getSIMStatus:error:", NO);
}

static id hook_copyLabel(id self, SEL cmd, id context, NSError **err)
{
    return GuardedCall((IMP)orig_copyLabel, self, cmd, context, err,
                       "copyLabel:error:", YES);
}

// 同族里其它“同步等 CommCenter”的取值方法，一并加超时，
// 免得 CCSIM 换个查询方法又卡死。签名都是 @32@0:8@16^@24。
#define GUARDED_CT_METHOD(name, str)                                            \
    static id (*orig_##name)(id, SEL, id, NSError **);                          \
    static id hook_##name(id self, SEL cmd, id arg, NSError **err)              \
    {                                                                           \
        return GuardedCall((IMP)orig_##name, self, cmd, arg, err, str, NO);     \
    }

GUARDED_CT_METHOD(getSimLabel, "getSimLabel:error:")
GUARDED_CT_METHOD(getShortLabel, "getShortLabel:error:")
GUARDED_CT_METHOD(copySIMIdentity, "copySIMIdentity:error:")
GUARDED_CT_METHOD(getMobileEquipmentInfoFor, "getMobileEquipmentInfoFor:error:")

static id hook_getSubscriptionInfoWithError(id self, SEL cmd, NSError **err)
{
    return GuardedCall((IMP)orig_getSubscriptionInfoWithError, self, cmd, nil, err,
                       "getSubscriptionInfoWithError", NO);
}

static id hook_getMobileEquipmentInfo(id self, SEL cmd, NSError **err)
{
    return GuardedCall((IMP)orig_getMobileEquipmentInfo, self, cmd, nil, err,
                       "getMobileEquipmentInfo:", NO);
}

#pragma mark - 安装

static void attemptInstall(void)
{
    if (gInstalled) return;

    Class client = objc_getClass("CoreTelephonyClient");
    MSHookFunc hook = hookFunction();
    if (!client || !hook) return;

    hook(client, @selector(getSIMStatus:error:),
                    (IMP)hook_getSIMStatus, (IMP *)&orig_getSIMStatus);
    hook(client, @selector(copyLabel:error:),
                    (IMP)hook_copyLabel, (IMP *)&orig_copyLabel);
    if (class_getInstanceMethod(client, @selector(getSubscriptionInfoWithError:)))
        hook(client, @selector(getSubscriptionInfoWithError:),
                        (IMP)hook_getSubscriptionInfoWithError,
                        (IMP *)&orig_getSubscriptionInfoWithError);
    if (class_getInstanceMethod(client, @selector(getMobileEquipmentInfo:)))
        hook(client, @selector(getMobileEquipmentInfo:),
                        (IMP)hook_getMobileEquipmentInfo,
                        (IMP *)&orig_getMobileEquipmentInfo);

#define OPTIONAL_HOOK(name)                                                     \
    if (class_getInstanceMethod(client, @selector(name:error:)))                \
        hook(client, @selector(name:error:),                         \
                        (IMP)hook_##name, (IMP *)&orig_##name);

    OPTIONAL_HOOK(getSimLabel)
    OPTIONAL_HOOK(getShortLabel)
    OPTIONAL_HOOK(copySIMIdentity)
    OPTIONAL_HOOK(getMobileEquipmentInfoFor)
#undef OPTIONAL_HOOK

    gInstalled = YES;
    os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT,
                     "CCSIMGuard: hooks installed on CoreTelephonyClient (pid %d)", getpid());
}

static void retryInstall(int attempt)
{
    if (gInstalled) return;
    attemptInstall();
    if (gInstalled) return;
    if (attempt >= kMaxRetries) {
        os_log_with_type(gLog, OS_LOG_TYPE_ERROR,
                         "CCSIMGuard: CoreTelephonyClient never appeared (pid %d)", getpid());
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   gQueue, ^{ retryInstall(attempt + 1); });
}

// CoreTelephony 有可能在插件之后才被载入，所以新 image 到达时也试一次。
static void imageAdded(const struct mach_header *mh, intptr_t slide)
{
    attemptInstall();
}

#ifdef CCSIMGUARD_TESTING
BOOL CCSIMGuardHooksInstalled(void) { return gInstalled; }
void CCSIMGuardInstallNow(void) { attemptInstall(); }
id CCSIMGuardTestGuard(IMP imp, id target, SEL cmd, id arg, NSError **err,
                     const char *what, BOOL owned)
{
    return GuardedCall(imp, target, cmd, arg, err, what, owned);
}
#endif

__attribute__((constructor)) static void CCSIMGuardInit(void)
{
    gLog = os_log_create(kSubsystem, "springboard");
    gQueue = dispatch_queue_create("com.netskao.ccsim.guard", NULL);
#ifdef APELIN_BUILD_ID
    os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT, "ApelinLoaded " APELIN_BUILD_ID);
#endif
    os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT, "CCSIMGuard: loaded (pid %d)", getpid());
    attemptInstall();
    _dyld_register_func_for_add_image(imageAdded);
    if (!gInstalled) retryInstall(0);
    // 便于事后确认：启动 3 秒后再报一次状态
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   gQueue, ^{
        os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT,
                         "CCSIMGuard: status installed=%d (pid %d)", (int)gInstalled, getpid());
    });
}
