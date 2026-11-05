// CPUthermal app-visible thermal state shield.
// Does not change thermalmonitord policy, CPU/GPU budgets, or the low-power mode.
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <dlfcn.h>
#import <notify.h>
#import <pthread.h>
#import <string.h>
#import <CPUthermalPaths.h>

static BOOL gCPUthermalAppShieldEnabled = NO;
static pthread_mutex_t gCPUthermalTokenLock = PTHREAD_MUTEX_INITIALIZER;
static int gCPUthermalTokens[16];
static size_t gCPUthermalTokenCount = 0;

typedef int (*CPUthermalNotifyRegisterCheckFn)(const char *, int *);
typedef uint32_t (*CPUthermalNotifyGetStateFn)(int, uint64_t *);
typedef int (*CPUthermalOSThermalLevelFn)(void);
static CPUthermalNotifyRegisterCheckFn gCPUthermalOrigNotifyRegisterCheck = NULL;
static CPUthermalNotifyGetStateFn gCPUthermalOrigNotifyGetState = NULL;
static CPUthermalOSThermalLevelFn gCPUthermalOrigOSThermalLevel = NULL;

static BOOL CPUthermalIsSensitiveThermalName(const char *name) {
    if (!name) return NO;
    return strcmp(name, "com.apple.system.thermalpressurelevel") == 0 ||
           strcmp(name, "com.apple.system.thermalnotification") == 0 ||
           strcmp(name, "com.apple.system.maxthermalsensorvalue") == 0;
}

static void CPUthermalRememberThermalToken(int token) {
    pthread_mutex_lock(&gCPUthermalTokenLock);
    for (size_t i = 0; i < gCPUthermalTokenCount; i++) {
        if (gCPUthermalTokens[i] == token) { pthread_mutex_unlock(&gCPUthermalTokenLock); return; }
    }
    if (gCPUthermalTokenCount < sizeof(gCPUthermalTokens) / sizeof(gCPUthermalTokens[0])) {
        gCPUthermalTokens[gCPUthermalTokenCount++] = token;
    }
    pthread_mutex_unlock(&gCPUthermalTokenLock);
}

static BOOL CPUthermalIsThermalToken(int token) {
    BOOL found = NO;
    pthread_mutex_lock(&gCPUthermalTokenLock);
    for (size_t i = 0; i < gCPUthermalTokenCount; i++) {
        if (gCPUthermalTokens[i] == token) { found = YES; break; }
    }
    pthread_mutex_unlock(&gCPUthermalTokenLock);
    return found;
}

static int CPUthermalHookedNotifyRegisterCheck(const char *name, int *outToken) {
    int result = gCPUthermalOrigNotifyRegisterCheck ? gCPUthermalOrigNotifyRegisterCheck(name, outToken) : NOTIFY_STATUS_FAILED;
    if (result == NOTIFY_STATUS_OK && outToken && CPUthermalIsSensitiveThermalName(name)) CPUthermalRememberThermalToken(*outToken);
    return result;
}

static uint32_t CPUthermalHookedNotifyGetState(int token, uint64_t *state) {
    uint32_t result = gCPUthermalOrigNotifyGetState ? gCPUthermalOrigNotifyGetState(token, state) : NOTIFY_STATUS_FAILED;
    if (result == NOTIFY_STATUS_OK && state && gCPUthermalAppShieldEnabled && CPUthermalIsThermalToken(token)) *state = 0;
    return result;
}

static int CPUthermalHookedOSThermalLevel(void) {
    if (gCPUthermalAppShieldEnabled) return 0;
    return gCPUthermalOrigOSThermalLevel ? gCPUthermalOrigOSThermalLevel() : 0;
}

%hook NSProcessInfo
- (NSInteger)thermalState {
    if (gCPUthermalAppShieldEnabled) return NSProcessInfoThermalStateNominal;
    return %orig;
}
%end

static void CPUthermalReloadAppShieldPreferences(void) {
    NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
    id enabled = prefs[S("enabled")];
    gCPUthermalAppShieldEnabled = enabled ? [enabled boolValue] : YES;
}

%ctor {
    @autoreleasepool {
        const char *process = getprogname();
        // SpringBoard has its own narrow module; daemons that enforce policy must always see reality.
        if (!process || strcmp(process, "SpringBoard") == 0 || strcmp(process, "thermalmonitord") == 0 ||
            strcmp(process, "backboardd") == 0 || strcmp(process, "powerd") == 0) return;
        CPUthermalReloadAppShieldPreferences();
        void *registerCheck = dlsym(RTLD_DEFAULT, "notify_register_check");
        void *getState = dlsym(RTLD_DEFAULT, "notify_get_state");
        void *thermalLevel = dlsym(RTLD_DEFAULT, "_OSThermalNotificationCurrentLevel");
        if (registerCheck) MSHookFunction(registerCheck, (void *)CPUthermalHookedNotifyRegisterCheck, (void **)&gCPUthermalOrigNotifyRegisterCheck);
        if (getState) MSHookFunction(getState, (void *)CPUthermalHookedNotifyGetState, (void **)&gCPUthermalOrigNotifyGetState);
        if (thermalLevel) MSHookFunction(thermalLevel, (void *)CPUthermalHookedOSThermalLevel, (void **)&gCPUthermalOrigOSThermalLevel);
    }
}
