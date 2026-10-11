// CPUthermalThermalWarn —— 高温警告抑制（面板开关 blockThermalPopup，默认开启）。
// 该子集从旧设置侧独立模块迁出，只保留“热状态伪装”部分：仅注入 SpringBoard。
// 设置侧其余钩子（部件/维修记录屏蔽等）未随迁；本文件不写文件、不做通知转发。
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <notify.h>
#import <dispatch/dispatch.h>
#import <ctype.h>
#import <string.h>
#import <CPUthermalPaths.h>

static BOOL gBlockThermalPopup = YES;  // 高温警告抑制：默认开启（偏好缺失时默认 YES，面板可关）
static int gThermalWarnSettingsToken = 0;

static void ReloadThermalWarnPreference(void) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    id v = prefs[S("blockThermalPopup")];
    gBlockThermalPopup = v ? [v boolValue] : YES;
}

static BOOL cStringContainsInsensitive(const char *value, const char *token) {
    if (!value || !token || !token[0]) {
        return NO;
    }

    size_t tokenLength = strlen(token);
    for (const char *cursor = value; *cursor; cursor++) {
        size_t index = 0;
        while (index < tokenLength && cursor[index] &&
               tolower((unsigned char)cursor[index]) == tolower((unsigned char)token[index])) {
            index++;
        }
        if (index == tokenLength) {
            return YES;
        }
    }

    return NO;
}

// ============================================================================
// 高温自动锁屏抑制（「屏蔽高温温度计警告」语义，恒开）
//   SpringBoard 依据进程内热状态/热通知等级触发“需要冷却”界面并自动锁屏；
//   仅拦截弹窗不够，锁屏动作仍会发生。这里把 SpringBoard 进程内所有热状态读取
//   伪装为正常（nominal / 0），使高温界面与自动锁屏都不再出现。
// ============================================================================
static BOOL CPUthermalIsThermalNotifyName(const char *name) {
    return name ? (cStringContainsInsensitive(name, "thermal") != NO) : NO;
}

static NSMutableSet *gThermalNotifyTokens = nil;
static os_unfair_lock gThermalTokenLock = OS_UNFAIR_LOCK_INIT;

static void CPUthermalRecordThermalToken(int token) {
    if (token <= 0) return;
    os_unfair_lock_lock(&gThermalTokenLock);
    if (!gThermalNotifyTokens) gThermalNotifyTokens = [NSMutableSet set];
    [gThermalNotifyTokens addObject:@(token)];
    os_unfair_lock_unlock(&gThermalTokenLock);
}

static BOOL CPUthermalIsThermalToken(int token) {
    os_unfair_lock_lock(&gThermalTokenLock);
    BOOL hit = [gThermalNotifyTokens containsObject:@(token)];
    os_unfair_lock_unlock(&gThermalTokenLock);
    return hit;
}

typedef int (*CPUthermalOSThermalLevelFn)(void);
static CPUthermalOSThermalLevelFn gOrigOSThermalLevel = NULL;
static int CPUthermalHookedOSThermalLevel(void) {
    if (gBlockThermalPopup) return 0;
    return gOrigOSThermalLevel ? gOrigOSThermalLevel() : 0;
}

typedef uint32_t (*CPUthermalNotifyGetStateFn)(int, uint64_t *);
static CPUthermalNotifyGetStateFn gOrigNotifyGetState = NULL;
static uint32_t CPUthermalHookedNotifyGetState(int token, uint64_t *state) {
    uint32_t result = gOrigNotifyGetState ? gOrigNotifyGetState(token, state) : 1;
    if (gBlockThermalPopup && state && CPUthermalIsThermalToken(token)) *state = 0;
    return result;
}

typedef uint32_t (*CPUthermalNotifyRegisterFn)(const char *, int *);
typedef uint32_t (*CPUthermalNotifyRegisterDispatchFn)(const char *, int *, dispatch_queue_t, notify_handler_t);
typedef uint32_t (*CPUthermalNotifyCancelFn)(int);
static CPUthermalNotifyRegisterFn gOrigNotifyRegisterCheck = NULL;
static CPUthermalNotifyRegisterDispatchFn gOrigNotifyRegisterDispatch = NULL;
static CPUthermalNotifyCancelFn gOrigNotifyCancel = NULL;
static uint32_t CPUthermalHookedNotifyRegisterCheck(const char *name, int *token) {
    uint32_t result = gOrigNotifyRegisterCheck ? gOrigNotifyRegisterCheck(name, token) : 1;
    if (result == 0 && token && CPUthermalIsThermalNotifyName(name)) CPUthermalRecordThermalToken(*token);
    return result;
}
static uint32_t CPUthermalHookedNotifyRegisterDispatch(const char *name, int *token, dispatch_queue_t queue, notify_handler_t handler) {
    uint32_t result = gOrigNotifyRegisterDispatch ? gOrigNotifyRegisterDispatch(name, token, queue, handler) : 1;
    if (result == 0 && token && CPUthermalIsThermalNotifyName(name)) CPUthermalRecordThermalToken(*token);
    return result;
}
static uint32_t CPUthermalHookedNotifyCancel(int token) {
    uint32_t result = gOrigNotifyCancel ? gOrigNotifyCancel(token) : 1;
    if (result == 0) {
        os_unfair_lock_lock(&gThermalTokenLock);
        [gThermalNotifyTokens removeObject:@(token)];
        os_unfair_lock_unlock(&gThermalTokenLock);
    }
    return result;
}

static void CPUthermalInstallThermalStateSpoof(void) {
    void *level = dlsym(RTLD_DEFAULT, "_OSThermalNotificationCurrentLevel");
    if (level) MSHookFunction(level, (void *)CPUthermalHookedOSThermalLevel, (void **)&gOrigOSThermalLevel);
    void *getState = dlsym(RTLD_DEFAULT, "notify_get_state");
    if (getState) MSHookFunction(getState, (void *)CPUthermalHookedNotifyGetState, (void **)&gOrigNotifyGetState);
    void *regCheck = dlsym(RTLD_DEFAULT, "notify_register_check");
    if (regCheck) MSHookFunction(regCheck, (void *)CPUthermalHookedNotifyRegisterCheck, (void **)&gOrigNotifyRegisterCheck);
    void *regDispatch = dlsym(RTLD_DEFAULT, "notify_register_dispatch");
    if (regDispatch) MSHookFunction(regDispatch, (void *)CPUthermalHookedNotifyRegisterDispatch, (void **)&gOrigNotifyRegisterDispatch);
    void *cancel = dlsym(RTLD_DEFAULT, "notify_cancel");
    if (cancel) MSHookFunction(cancel, (void *)CPUthermalHookedNotifyCancel, (void **)&gOrigNotifyCancel);
}

%hook NSProcessInfo

- (NSInteger)thermalState {
    if (gBlockThermalPopup) return 0;   // NSProcessInfoThermalStateNominal
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        ReloadThermalWarnPreference();
        CPUthermalInstallThermalStateSpoof();
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gThermalWarnSettingsToken,
                                 dispatch_get_main_queue(), ^(int token) {
            (void)token;
            ReloadThermalWarnPreference();
        });
    }
}
