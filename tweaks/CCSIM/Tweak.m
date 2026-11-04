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
#import <spawn.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <limits.h>
#import <errno.h>
#import <stdarg.h>
#import <sys/stat.h>
#import <time.h>

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
static BOOL gInstalled;   // 不再重试（装好了，或这台系统不需要装）
static BOOL gHooked;      // 真的装上了 hook
static BOOL gGuard;       // iOS 17+ 才做超时；否则只记录、原样返回
static int gTimeoutStreak;
static CFAbsoluteTime gCoolDownUntil;

static const char *NowStr(void)
{
    static char b[32];
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(b, sizeof(b), "%m-%d %H:%M:%S", &tmv);
    return b;
}

// 诊断日志三条道一起写：
//   os_log（实时，每次监听只能看到新产生的行）
//   文件（首选 /var/mobile/Library/SpringBoard，依次回退）
//   偏好域 com.netskao.ccsim.guarddiag 的 events 数组（cfprefsd 负责落盘，沙箱挡不住，
//   事后用 icli prefs read 一读就有）
static void PrefLogRaw(const char *line)
{
    static CFStringRef appID;
    static CFStringRef key;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        appID = CFSTR("com.netskao.ccsim.guarddiag");
        key = CFSTR("events");
    });

    CFStringRef entry = CFStringCreateWithCString(kCFAllocatorDefault, line,
                                                  kCFStringEncodingUTF8);
    if (!entry) return;

    CFMutableArrayRef arr = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    CFTypeRef old = CFPreferencesCopyAppValue(key, appID);
    if (old && CFGetTypeID(old) == CFArrayGetTypeID()) {
        CFArrayRef o = (CFArrayRef)old;
        CFIndex n = CFArrayGetCount(o);
        for (CFIndex i = (n > 29 ? n - 29 : 0); i < n; i++)
            CFArrayAppendValue(arr, CFArrayGetValueAtIndex(o, i));
    }
    if (old) CFRelease(old);
    CFArrayAppendValue(arr, entry);
    CFPreferencesSetAppValue(key, arr, appID);
    CFPreferencesAppSynchronize(appID);
    CFRelease(arr);
    CFRelease(entry);
}

static void LogEvent(const char *fmt, ...)
{
    char line[480];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);

    char stamped[512];
    snprintf(stamped, sizeof(stamped), "%s %s", NowStr(), line);

    os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT, "CCSIMGuard: %{public}s", line);
    PrefLogRaw(stamped);

    static FILE *fp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char *dirs[] = {
            "/var/mobile/Library/SpringBoard",
            "/var/mobile/Library/CCSIMGuard",
            "/var/mobile/Library/Preferences",
            "/var/mobile/tmp",
            "/tmp",
        };
        for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]) && !fp; i++) {
            mkdir(dirs[i], 0755);
            char p[PATH_MAX];
            snprintf(p, sizeof(p), "%s/CCSIMGuard.log", dirs[i]);
            struct stat st;
            if (stat(p, &st) == 0 && st.st_size > 256 * 1024) unlink(p);
            fp = fopen(p, "a");
        }
    });
    if (fp) {
        fprintf(fp, "%s\n", stamped);
        fflush(fp);
    }
}

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
        LogEvent("%s timed out after %.1fs", what, kTimeout);
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

    // 所有权保守处理：无论原实现的约定是 +0 还是 +1，都把这次 retain 过的
    // +1 直接交出去。最坏情况是泄漏一个对象，绝不会让调用方拿到已释放的
    // 对象（之前按 get 语义 autorelease 可能过度释放，导致模块读不到状态）。
    (void)wantOwned;
    return result;
}

#pragma mark - hooks

// iOS 16 及更早：装同样的 hook，但不改行为，只把调用和返回记下来，
// 好判断模块到底问了什么、拿到了什么。
static id PassThrough(IMP imp, id self, SEL cmd, id arg, NSError **errOut, const char *what)
{
    id r = ((id (*)(id, SEL, id, NSError **))imp)(self, cmd, arg, errOut);
    LogEvent("%s%s -> %s", what, errOut && *errOut ? " (err)" : "",
             r ? object_getClassName(r) : "nil");
    return r;
}

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
    if (!gGuard) return PassThrough((IMP)orig_getSIMStatus, self, cmd, context, err,
                                    "getSIMStatus:error:");
    return GuardedCall((IMP)orig_getSIMStatus, self, cmd, context, err,
                       "getSIMStatus:error:", NO);
}

static id hook_copyLabel(id self, SEL cmd, id context, NSError **err)
{
    if (!gGuard) return PassThrough((IMP)orig_copyLabel, self, cmd, context, err,
                                    "copyLabel:error:");
    return GuardedCall((IMP)orig_copyLabel, self, cmd, context, err,
                       "copyLabel:error:", YES);
}

// 同族里其它“同步等 CommCenter”的取值方法，一并加超时，
// 免得 CCSIM 换个查询方法又卡死。签名都是 @32@0:8@16^@24。
#define GUARDED_CT_METHOD(name, str)                                            \
    static id (*orig_##name)(id, SEL, id, NSError **);                          \
    static id hook_##name(id self, SEL cmd, id arg, NSError **err)              \
    {                                                                           \
        if (!gGuard) return PassThrough((IMP)orig_##name, self, cmd, arg, err, str); \
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

#pragma mark - posix_spawn 兜底

// 上游 bundle 里写死了 /var/jb/usr/local/bin/CCSIMTool 这类 rootless 路径，
// roothide 上真实文件系统没有 /var/jb（只有隐根），路径补丁一旦没生效，
// 点开关就 spawn 不到工具、什么也不会发生。这里在 spawn 时把 /var/jb 前缀
// 映射到隐根（用 libroothide 的 jbroot()），路径本来就能用时原样放行。
typedef int (*spawn_fn)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                        const posix_spawnattr_t *, char *const[], char *const[]);
typedef void (*hook_fn)(void *target, void *replacement, void **result);

static spawn_fn gOrigSpawn;
static hook_fn gHookFunc;
typedef char *(*jbroot_fn)(const char *);
static char gJBRoot[PATH_MAX];

// 找隐根前缀：优先 libroothide 的 jbroot()，取不到就从我们自己的 dylib 路径反推
// （插件就在 <jbroot>/Library/MobileSubstrate/DynamicLibraries/ 下）。
static void loadJBRoot(void)
{
    if (gJBRoot[0]) return;

    void *h = dlopen("/usr/lib/libroothide.dylib", RTLD_LAZY);
    if (!h) h = dlopen("libroothide.dylib", RTLD_LAZY);
    jbroot_fn jb = h ? (jbroot_fn)dlsym(h, "jbroot") : NULL;
    if (!jb) jb = (jbroot_fn)dlsym(RTLD_DEFAULT, "jbroot");
    if (jb) {
        char *root = jb("/");
        if (root && *root) {
            snprintf(gJBRoot, sizeof(gJBRoot), "%s", root);
            size_t n = strlen(gJBRoot);
            while (n > 1 && gJBRoot[n - 1] == '/') gJBRoot[--n] = 0;
        }
    }

    if (!gJBRoot[0]) {
        Dl_info info;
        if (dladdr((void *)LogEvent, &info) && info.dli_fname) {
            const char *mark = "/Library/MobileSubstrate/DynamicLibraries/";
            const char *hit = strstr(info.dli_fname, mark);
            if (hit) {
                size_t n = (size_t)(hit - info.dli_fname);
                if (n > 0 && n < sizeof(gJBRoot)) {
                    memcpy(gJBRoot, info.dli_fname, n);
                    gJBRoot[n] = 0;
                }
            }
        }
    }
}

static const char *resolveJBPath(const char *path, char *out, size_t outLen)
{
    if (!path) return path;
    if (strncmp(path, "/var/jb/", 8) != 0) return path;      // 不是 rootless 写法
    if (access(path, X_OK) == 0) return path;                // rootless 上本来就通

    loadJBRoot();
    if (!gJBRoot[0]) return path;
    snprintf(out, outLen, "%s%s", gJBRoot, path + 7);
    return out;
}

static int hookedPosixSpawn(pid_t *pid, const char *path,
                            const posix_spawn_file_actions_t *fa,
                            const posix_spawnattr_t *attr,
                            char *const argv[], char *const envp[])
{
    char mapped[PATH_MAX];
    const char *use = resolveJBPath(path, mapped, sizeof(mapped));
    int rc = gOrigSpawn(pid, use, fa, attr, argv, envp);
    if (use != path) {
        os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT,
                         "CCSIMGuard: spawn %{public}s -> %{public}s rc=%d",
                         path, use, rc);
        LogEvent("spawn %s -> %s rc=%d", path, use, rc);
    } else {
        os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT,
                         "CCSIMGuard: spawn %{public}s rc=%d", path, rc);
        LogEvent("spawn %s rc=%d", path, rc);
    }
    return rc;
}

static void InstallSpawnHook(void)
{
    static BOOL done;
    if (done) return;
    if (!gHookFunc) gHookFunc = (hook_fn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!gHookFunc) return;
    gHookFunc((void *)posix_spawn, (void *)hookedPosixSpawn, (void **)&gOrigSpawn);
    done = YES;
    os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT,
                     "CCSIMGuard: posix_spawn hook installed (pid %d)", getpid());
    LogEvent("posix_spawn hook installed (pid %d)", getpid());
    loadJBRoot();
    LogEvent("jbroot=%s ; /var/jb tool reachable=%d", 
            gJBRoot[0] ? gJBRoot : "(unknown)",
            access("/var/jb/usr/local/bin/CCSIMTool", X_OK) == 0);
}

#pragma mark - CellularPlanManager 诊断

// 模块真正切换 SIM 卡要经过 CTCellularPlanManager（可能运行时 dlopen 进来），
// 这里只记录调用与返回值，不改行为。
typedef id (*planItems_fn)(id, SEL, BOOL);
typedef id (*didSelect_fn)(id, SEL, id, BOOL);
static planItems_fn orig_planItems;
static didSelect_fn orig_didSelect;

static id hook_planItemsShouldUpdate(id self, SEL cmd, BOOL shouldUpdate)
{
    id r = orig_planItems(self, cmd, shouldUpdate);
    LogEvent("planItemsShouldUpdate:%d -> %s", (int)shouldUpdate,
             r ? object_getClassName(r) : "nil");
    return r;
}

static id hook_didSelectPlanItem(id self, SEL cmd, id item, BOOL isEnable)
{
    LogEvent("didSelectPlanItem:%s isEnable:%d (calling)",
             item ? object_getClassName(item) : "nil", (int)isEnable);
    id r = orig_didSelect(self, cmd, item, isEnable);
    LogEvent("didSelectPlanItem isEnable:%d -> %s", (int)isEnable,
             r ? object_getClassName(r) : "nil");
    return r;
}

static void InstallPlanManagerHooks(void)
{
    static BOOL done;
    if (done) return;
    MSHookFunc hook = hookFunction();
    Class pm = objc_getClass("CTCellularPlanManager");
    if (!hook || !pm) return;
    if (class_getInstanceMethod(pm, @selector(planItemsShouldUpdate:)))
        hook(pm, @selector(planItemsShouldUpdate:), (IMP)hook_planItemsShouldUpdate,
             (IMP *)&orig_planItems);
    if (class_getInstanceMethod(pm, @selector(didSelectPlanItem:isEnable:)))
        hook(pm, @selector(didSelectPlanItem:isEnable:), (IMP)hook_didSelectPlanItem,
             (IMP *)&orig_didSelect);
    done = YES;
    LogEvent("CTCellularPlanManager hooks installed");
}

#pragma mark - 安装

static void attemptInstall(void)
{
    // 与 iOS 版本无关：修 /var/jb 路径，保证模块能启动 CCSIMTool
    InstallSpawnHook();
    InstallPlanManagerHooks();

    if (gInstalled) return;

#ifndef CCSIMGUARD_TESTING
    static BOOL versionChecked;
    if (!versionChecked) {
        versionChecked = YES;
        NSOperatingSystemVersion need = { 17, 0, 0 };
        gGuard = [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:need];
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        LogEvent("iOS %ld.%ld -> guard=%d (0 = 只记录不改行为)",
                 (long)v.majorVersion, (long)v.minorVersion, (int)gGuard);
    }
#endif

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
    gHooked = YES;
    os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT,
                     "CCSIMGuard: hooks installed on CoreTelephonyClient (pid %d)", getpid());
    LogEvent("CT hooks installed (pid %d)", getpid());
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
    InstallPlanManagerHooks();
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
    LogEvent("loaded (pid %d)", getpid());
    attemptInstall();
    _dyld_register_func_for_add_image(imageAdded);
    if (!gInstalled) retryInstall(0);
    // 便于事后确认：启动 3 秒后再报一次状态
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   gQueue, ^{
        os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT,
                         "CCSIMGuard: status hooked=%d (pid %d)", (int)gHooked, getpid());
    });
}
