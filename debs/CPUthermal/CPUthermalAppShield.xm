// isolation.39: 普通应用侧热状态伪装模块（纯 Foundation，不依赖 UIKit/SpringBoard）。
// 只做“读取侧伪装”：NSProcessInfo.thermalState、_OSThermalNotificationCurrentLevel
// 以及四个 thermal 通知 token 的 notify_get_state 一律返回 0（nominal）。
// 不读取、不修改运行模式偏好，不触碰低功耗 2500mW / 45% / Level2 的 CPU 链——
// 本模块只影响应用自己看到的读数，不参与任何预算/频率决策。
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <CPUthermalPaths.h>

// 总开关：偏好缺失时默认启用（isolation.39 设计），面板写入后经 settingsChanged 即时生效。
static BOOL gAppShieldEnabled = YES;
static int gAppShieldSettingsToken = -1;

// 只有这四个进程不注入语义：SpringBoard / thermalmonitord / backboardd / powerd。
// filter plist 无法表达“排除”，因此在进程内做闸门；被排除的进程不会安装任何钩子。
static const char * const kCPUthermalAppShieldExcludedProcesses[] = {
    "SpringBoard", "thermalmonitord", "backboardd", "powerd", NULL
};

// 由 notify_register_check 识别到的 thermal token 表（固定容量，令牌数量极少）。
#define kCPUthermalThermalTokenSlots 8
static int gThermalTokens[kCPUthermalThermalTokenSlots];
static int gThermalTokenCount = 0;
static os_unfair_lock gThermalTokenLock = OS_UNFAIR_LOCK_INIT;

static const char * const kCPUthermalThermalNotifyNames[] = {
    "com.apple.system.thermalpressurelevel",
    "com.apple.system.thermalnotification",
    "com.apple.system.maxthermalsensorvalue",
    "com.apple.system.thermalsunlightstate",
    NULL
};

static BOOL CPUthermalAppShieldIsEnabled(void) {
    return __atomic_load_n(&gAppShieldEnabled, __ATOMIC_ACQUIRE);
}

static void CPUthermalReloadAppShieldPreferences(void) {
    @autoreleasepool {
        NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
        id value = prefs ? prefs[S("appShieldEnabled")] : nil;
        BOOL enabled = YES;                              // 缺失 = 启用
        if ([value respondsToSelector:@selector(boolValue)]) enabled = [value boolValue];
        __atomic_store_n(&gAppShieldEnabled, enabled, __ATOMIC_RELEASE);
    }
}

static BOOL CPUthermalIsThermalNotifyName(const char *name) {
    if (!name) return NO;
    for (int i = 0; kCPUthermalThermalNotifyNames[i]; i++) {
        if (strcmp(name, kCPUthermalThermalNotifyNames[i]) == 0) return YES;
    }
    return NO;
}

static void CPUthermalRememberThermalToken(int token) {
    if (token < 0) return;
    os_unfair_lock_lock(&gThermalTokenLock);
    for (int i = 0; i < gThermalTokenCount; i++) {
        if (gThermalTokens[i] == token) {
            os_unfair_lock_unlock(&gThermalTokenLock);
            return;
        }
    }
    if (gThermalTokenCount < kCPUthermalThermalTokenSlots) {
        gThermalTokens[gThermalTokenCount++] = token;
    }
    os_unfair_lock_unlock(&gThermalTokenLock);
}

static BOOL CPUthermalIsThermalToken(int token) {
    if (token < 0) return NO;
    BOOL found = NO;
    os_unfair_lock_lock(&gThermalTokenLock);
    for (int i = 0; i < gThermalTokenCount; i++) {
        if (gThermalTokens[i] == token) { found = YES; break; }
    }
    os_unfair_lock_unlock(&gThermalTokenLock);
    return found;
}

static BOOL CPUthermalNameInList(NSString *name, const char * const *list) {
    if (name.length == 0) return NO;
    for (int i = 0; list[i]; i++) {
        if ([name caseInsensitiveCompare:S(list[i])] == NSOrderedSame) return YES;
    }
    return NO;
}

// 只处理“普通应用”：进程名不在排除表，且主 bundle 位于应用容器（不是系统守护/框架）。
static BOOL CPUthermalAppShieldProcessAllowed(void) {
    NSString *processName = [[NSProcessInfo processInfo] processName];
    if (CPUthermalNameInList(processName, kCPUthermalAppShieldExcludedProcesses)) return NO;
    const char *prog = getprogname();
    if (prog && CPUthermalNameInList(S(prog), kCPUthermalAppShieldExcludedProcesses)) return NO;
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleID = [bundle bundleIdentifier];
    NSString *bundlePath = [bundle bundlePath];
    if (bundleID.length == 0 || bundlePath.length == 0) return NO;
    if ([bundlePath hasPrefix:S("/System/")] || [bundlePath hasPrefix:S("/private/preboot/")]) return NO;
    return YES;
}

typedef int (*CPUthermalOSThermalLevelFn)(void);
static CPUthermalOSThermalLevelFn gOriginalOSThermalLevel = NULL;

static int CPUthermalHookedOSThermalLevel(void) {
    if (CPUthermalAppShieldIsEnabled()) return 0;
    return gOriginalOSThermalLevel ? gOriginalOSThermalLevel() : 0;
}

typedef uint32_t (*CPUthermalNotifyRegisterCheckFn)(const char *, int *);
static CPUthermalNotifyRegisterCheckFn gOriginalNotifyRegisterCheck = NULL;

static uint32_t CPUthermalHookedNotifyRegisterCheck(const char *name, int *outToken) {
    uint32_t status = gOriginalNotifyRegisterCheck
        ? gOriginalNotifyRegisterCheck(name, outToken)
        : (uint32_t)NOTIFY_STATUS_FAILED;
    if (status == NOTIFY_STATUS_OK && outToken && CPUthermalIsThermalNotifyName(name)) {
        CPUthermalRememberThermalToken(*outToken);
    }
    return status;
}

typedef uint32_t (*CPUthermalNotifyGetStateFn)(int, uint64_t *);
static CPUthermalNotifyGetStateFn gOriginalNotifyGetState = NULL;

static uint32_t CPUthermalHookedNotifyGetState(int token, uint64_t *state) {
    if (state && CPUthermalAppShieldIsEnabled() && CPUthermalIsThermalToken(token)) {
        *state = 0;                                      // nominal：热压/热通知/传感器/阳光暴露
        return (uint32_t)NOTIFY_STATUS_OK;
    }
    return gOriginalNotifyGetState
        ? gOriginalNotifyGetState(token, state)
        : (uint32_t)NOTIFY_STATUS_FAILED;
}

%hook NSProcessInfo
- (NSInteger)thermalState {
    if (CPUthermalAppShieldIsEnabled()) return 0;
    return %orig;
}
%end

static void CPUthermalInstallAppShieldHooks(void) {
    void *levelSymbol = dlsym(RTLD_DEFAULT, "_OSThermalNotificationCurrentLevel");
    if (levelSymbol) {
        MSHookFunction(levelSymbol, (void *)CPUthermalHookedOSThermalLevel,
                       (void **)&gOriginalOSThermalLevel);
    }
    void *registerSymbol = dlsym(RTLD_DEFAULT, "notify_register_check");
    if (registerSymbol) {
        MSHookFunction(registerSymbol, (void *)CPUthermalHookedNotifyRegisterCheck,
                       (void **)&gOriginalNotifyRegisterCheck);
    }
    void *stateSymbol = dlsym(RTLD_DEFAULT, "notify_get_state");
    if (stateSymbol) {
        MSHookFunction(stateSymbol, (void *)CPUthermalHookedNotifyGetState,
                       (void **)&gOriginalNotifyGetState);
    }
}

%ctor {
    @autoreleasepool {
        if (!CPUthermalAppShieldProcessAllowed()) return;   // 排除进程/非应用：不安装任何钩子
        CPUthermalReloadAppShieldPreferences();
        CPUthermalInstallAppShieldHooks();
        dispatch_queue_t queue = dispatch_queue_create("com.huayuarc.cputhermal.app-shield.prefs",
                                                       DISPATCH_QUEUE_SERIAL);
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gAppShieldSettingsToken,
                                 queue, ^(int token) {
            (void)token;
            CPUthermalReloadAppShieldPreferences();
        });
    }
}
